module CityWorkers
  # Mantém um supervisor Solid Queue por cidade ativa, mais o da plataforma (spec
  # banco-por-cidade §4 e riscos abertos 1, Plano 5). Um laço de reconciliação:
  #   - lê o catálogo a cada poll_interval: cidades active com schema em dia — uma
  #     cidade atrasada sai e volta sozinha depois do city:migrate:all;
  #   - sobe o que falta e manda TERM a quem saiu do catálogo;
  #   - reinicia quem morreu sem ter sido parado, com Backoff.
  # Não guarda estado em banco: cada gerente descobre as cidades sozinho. Processo,
  # relógio e catálogo são injetados, para o laço ser testável sem fork.
  class Manager
    Running = Struct.new(:unit, :pid, :started_at, keyword_init: true)

    # Reap final do shutdown (Minor 2, fix round 1): depois do KILL, o SO ainda
    # leva um instante para marcar o processo como zumbi. Sem esta janela, o
    # último `reap` corria cedo demais e o `bin/city_workers` saía sem drenar os
    # filhos que o KILL tinha, sim, matado.
    FINAL_REAP_TIMEOUT = 2.0

    attr_reader :running

    def self.active_city_slugs
      City.where(status: "active").order(:slug).reject { |city| CitySchema.behind?(city) }.map(&:slug)
    end

    def initialize(spawner:, clock:, catalog:, backoff: Backoff.new, poll_interval: 30.0,
                   stop_timeout: SolidQueue.shutdown_timeout.to_f + 5.0, logger: Rails.logger)
      @spawner = spawner
      @clock = clock
      @catalog = catalog
      @backoff = backoff
      @poll_interval = poll_interval
      @stop_timeout = stop_timeout
      @logger = logger
      @running = {}
      @failures = Hash.new(0)
      @next_start_at = {}
      @stopping = {}
      @stop_deadline = {}
      @desired = nil
      @last_poll_at = nil
    end

    def run(stop_signal:)
      until stop_signal.call
        tick
        @clock.sleep(1.0)
      end
      shutdown(timeout: @stop_timeout)
    end

    def tick
      refresh_desired if poll_due?
      reap
      stop_undesired
      escalate_stalled_stops
      start_missing
    end

    def shutdown(timeout:)
      running.each_value do |entry|
        @stopping[entry.pid] = true
        @spawner.terminate(entry.pid)
      end

      deadline = @clock.now + timeout
      until running.empty? || @clock.now >= deadline
        reap
        @clock.sleep(0.1) unless running.empty?
      end

      running.each_value do |entry|
        @logger.warn("[city_workers] #{entry.unit.key} não parou em #{timeout}s: KILL (pid #{entry.pid})")
        @spawner.kill(entry.pid)
      end

      final_deadline = @clock.now + FINAL_REAP_TIMEOUT
      until running.empty? || @clock.now >= final_deadline
        reap
        @clock.sleep(0.1) unless running.empty?
      end
      reap
    end

    private

    def desired
      @desired || [ Unit.platform ]
    end

    def poll_due?
      @last_poll_at.nil? || @clock.now - @last_poll_at >= @poll_interval
    end

    def refresh_desired
      @last_poll_at = @clock.now
      @desired = [ Unit.platform ] + @catalog.call.map { |slug| Unit.city(slug) }
    rescue StandardError => e
      @logger.error("[city_workers] catálogo indisponível, mantendo o que roda: #{e.class}: #{CitySchema.redact(e.message)}")
    end

    def reap
      @spawner.reap.each do |pid, status|
        entry = running.values.find { |candidate| candidate.pid == pid } or next
        key = entry.unit.key
        running.delete(key)

        if @stopping.delete(pid)
          @failures.delete(key)
          @next_start_at.delete(key)
          @stop_deadline.delete(pid)
          @logger.info("[city_workers] #{key} parou (pid #{pid})")
        else
          @failures[key] = @backoff.failures_after_exit(@failures[key], ran_for: @clock.now - entry.started_at)
          delay = @backoff.delay_for(@failures[key])
          @next_start_at[key] = @clock.now + delay
          @logger.warn("[city_workers] #{key} morreu (pid #{pid}, #{status}); reinicia em #{delay}s (falha #{@failures[key]})")
        end
      end
    end

    def stop_undesired
      keys = desired.map(&:key)
      running.each_value do |entry|
        next if keys.include?(entry.unit.key) || @stopping[entry.pid]

        @logger.info("[city_workers] #{entry.unit.key} saiu do catálogo: TERM (pid #{entry.pid})")
        @stopping[entry.pid] = true
        @stop_deadline[entry.pid] = @clock.now + @stop_timeout
        @spawner.terminate(entry.pid)
      end
    end

    # Um TERM enviado enquanto o filho ainda inicializa (antes do Solid Queue
    # instalar os próprios traps) não faz nada: só o KILL do Spawner (grupo
    # inteiro) resolve (Important 1, fix round 1). O relógio injetado é o mesmo
    # que o resto do laço usa, então o spec não precisa de sleep de verdade.
    def escalate_stalled_stops
      @stop_deadline.keys.each do |pid|
        next if @clock.now < @stop_deadline[pid]

        entry = running.values.find { |candidate| candidate.pid == pid }
        if entry
          @logger.warn("[city_workers] #{entry.unit.key} não respondeu ao TERM: KILL (pid #{pid})")
          @spawner.kill(pid)
        end
        @stop_deadline.delete(pid)
      end
    end

    def start_missing
      desired.each do |unit|
        next if running.key?(unit.key)
        next if @next_start_at[unit.key] && @clock.now < @next_start_at[unit.key]

        pid = @spawner.spawn(unit)
        running[unit.key] = Running.new(unit: unit, pid: pid, started_at: @clock.now)
        @logger.info("[city_workers] #{unit.key} subiu (pid #{pid})")
      end
    end
  end
end
