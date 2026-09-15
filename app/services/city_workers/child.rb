module CityWorkers
  # O que roda dentro do fork de uma unidade (spec §4, spike 2): liga o Solid Queue
  # ao banco certo e entra no supervisor.
  #   - cidade: o padrão do SolidQueue::Record passa a ser o banco da cidade para o
  #     processo inteiro (todas as threads do supervisor e dos workers que ele
  #     forka), e CityWorkers::Context marca a cidade do processo;
  #   - plataforma: o padrão já é o banco de plataforma (config.solid_queue.connects_to).
  # Uma cidade que deixou de estar active, ou atrasou o schema, entre a leitura do
  # catálogo e o fork levanta CityUnavailable: o filho sai com erro, o Manager
  # espera o backoff e a tira no próximo poll.
  module Child
    class CityUnavailable < StandardError; end

    # Intervalo do watchdog que checa se o Manager que forkou este filho ainda é
    # o pai (Important 2, fix round 1).
    WATCHDOG_INTERVAL = 1.0

    module_function

    # Roda o supervisor de verdade (Spawner#spawn). Um problema de boot (cidade
    # indisponível, catálogo inacessível, banco fora do ar) sai com uma linha só,
    # sem stack trace e sem os at_exit herdados do pai (Minor 4, fix round 1):
    # sem isto, uma exceção não tratada dentro do bloco de Process.fork imprime
    # backtrace e roda os at_exit do processo pai inteiro.
    def run(unit, manager_pid: Process.ppid)
      start_watchdog(manager_pid)
      SolidQueue::Supervisor.start(**prepare(unit))
    rescue StandardError => e
      warn(CitySchema.redact("[city_workers] #{unit.key}: não subiu (#{e.class}): #{e.message}"))
      exit!(1)
    end

    # true quando o processo pai deixou de ser o Manager que o forkou (Important
    # 2, fix round 1): o Solid Queue já vigia os PRÓPRIOS filhos (workers e
    # dispatcher) pelo ppid, mas ninguém vigiava o supervisor em si — um Manager
    # morto de SIGKILL nunca manda TERM, e a árvore inteira ficava órfã para
    # sempre. Método isolado do `Thread.new` para dar para testar sem watchdog de
    # verdade.
    def orphaned?(manager_pid)
      Process.ppid != manager_pid
    end

    def prepare(unit)
      Process.setpgid(0, 0)

      if unit.kind == :city
        city = City.find_by(slug: unit.city_slug)
        unless city&.servable? && !CitySchema.behind?(city)
          raise CityUnavailable, "cidade #{unit.city_slug} fora do ar ou com schema atrasado"
        end

        CityWorkers::Context.city_slug = city.slug
        CityConnection.ensure_pool(city)
        SolidQueue::Record.establish_connection(CityConnection.database_config(city))
      end

      {
        mode: :fork,
        config_file: Rails.root.join(unit.config_file),
        recurring_schedule_file: Rails.root.join(unit.recurring_schedule_file)
      }
    end

    def start_watchdog(manager_pid)
      Thread.new do
        loop do
          sleep(WATCHDOG_INTERVAL)
          if orphaned?(manager_pid)
            Process.kill("TERM", Process.pid)
            break
          end
        end
      end
    end
  end
end
