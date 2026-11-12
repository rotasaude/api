require "rails_helper"

# Review Focus 2 do plano do 33 (ADR 0051; contrato §4): a corrida na borda do
# teto da denúncia anônima. Teto 2, uma já gravada no dia; três envios ao
# mesmo tempo. O primeiro fica parado depois de gravar (antes do commit),
# segurando a linha de ombudsman_settings (FOR UPDATE); os outros dois esperam
# a trava. Solta o primeiro: ele grava, os dois seguintes contam 2 e recebem
# daily_cap_reached, e só o primeiro bloqueio do dia publica
# ombudsman.anonymous_cap_reached. Threads reais contra TEST_CITY_A (sem
# fixture transacional), no padrão do módulo 09
# (spec/models/health_unit_lock_spec.rb): pop(timeout:), e o after solta as
# threads, apaga o que commitou e devolve o teto.
RSpec.describe "Ombudsman::RegisterAnonymous — concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { { manifestations: [] } }
  let(:text) { "Denúncia anônima feita ao mesmo tempo que outras duas." }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def anonymous_today = OmbudsmanManifestation.where(channel: "web", identification_mode: "anonymous", received_at: Time.current.all_day)

  before do
    in_city do
      Ombudsman::Settings.ensure_defaults!
      raise "TEST_CITY_A já tem denúncia anônima commitada" if anonymous_today.exists?
      raise "TEST_CITY_A já tem a marca do teto de hoje" if OmbudsmanDailyRun.exists?(kind: "anonymous_cap", run_on: Time.zone.today)

      ids[:cap] = OmbudsmanSetting.current.anonymous_daily_cap
      OmbudsmanSetting.current.update!(anonymous_daily_cap: 2)
      first = Ombudsman::RegisterAnonymous.call(body: text, health_unit_id: nil, now: Time.current)
      raise "a primeira denúncia foi recusada: #{first.reason}" if first.failure?

      ids[:manifestations] << first.payload.fetch(:manifestation).id
    end
  end

  after do
    4.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        manifestation_ids = (ids[:manifestations] + anonymous_today.pluck(:id)).uniq
        DomainEvent.where(name: "ombudsman.anonymous_cap_reached").delete_all
        DomainEvent.where(name: "ombudsman.manifestation_received")
                   .where("payload->>'manifestation_id' IN (?)", manifestation_ids.presence || [ "" ]).delete_all
        OmbudsmanEvent.where(ombudsman_manifestation_id: manifestation_ids).delete_all
        OmbudsmanManifestation.where(id: manifestation_ids).delete_all
        OmbudsmanDailyRun.where(kind: "anonymous_cap", run_on: Time.zone.today).delete_all
        OmbudsmanSetting.where(id: 1).update_all(anonymous_daily_cap: ids[:cap]) if ids[:cap]
      end
    end
  end

  # Espera até `count` conexões paradas numa trava do Postgres.
  def wait_for_lock_waiters(count, timeout: 5)
    deadline = Time.current + timeout
    loop do
      waiting = ApplicationRecord.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      ).to_i
      return true if waiting >= count
      return false if Time.current > deadline

      sleep 0.05
    end
  end

  it "teto 2 com uma já gravada: três ao mesmo tempo → uma grava, duas daily_cap_reached, um evento" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "ombudsman.manifestation_received"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    run = -> { in_city { Ombudsman::RegisterAnonymous.call(body: text, health_unit_id: nil, now: Time.current) } }

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << run.call })
    holding.pop(timeout: 5) or raise "o primeiro envio não chegou a gravar"

    others = Queue.new
    2.times { threads << Thread.new { others << run.call } }
    in_city { expect(wait_for_lock_waiters(2)).to be(true) } # os dois esperam a linha do teto

    release << true
    threads.each { |t| expect(t.join(5)).to be(t) }
    first = first_result.pop(timeout: 1)
    rest = [ others.pop(timeout: 1), others.pop(timeout: 1) ]
    expect(first).to be_ok
    expect(rest.map(&:reason)).to eq(%i[daily_cap_reached daily_cap_reached])
    ids[:manifestations] << first.payload.fetch(:manifestation).id

    in_city do
      expect(anonymous_today.count).to eq(2)
      expect(DomainEvent.where(name: "ombudsman.anonymous_cap_reached").sole.payload).to eq({})
      expect(OmbudsmanDailyRun.where(kind: "anonymous_cap", run_on: Time.zone.today).count).to eq(1)
    end
  end
end
