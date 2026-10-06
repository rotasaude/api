# spec/jobs/ledi/deliver_job_concurrency_spec.rb
require "rails_helper"

# Spec §9 "SKIP LOCKED com duas threads". Threads reais contra TEST_CITY_A, sem
# fixture transacional (como spec/jobs/campaigns/due_job_concurrency_spec.rb):
# a primeira execução para DENTRO da transação de reivindicação (gancho em
# mark_sending); a segunda passa por cima das linhas travadas sem esperar e
# não envia nada. O after apaga TUDO o que commitou (cidade e plataforma):
# triggers desligados só na transação da limpeza.
RSpec.describe Ledi::DeliverJob, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:started_at) { Time.current - 1.second }
  # Estado anterior (a plataforma de teste é compartilhada): só apagamos o que criamos.
  let!(:created_city) { City.find_by(slug: TEST_CITY_A.slug).nil? }
  let!(:prior_city) { City.find_by(slug: TEST_CITY_A.slug)&.slice(:record_mode, :pec_url) }
  let!(:created_maintainer) { Maintainer.find_by(email_address: "ledi-mantenedor@rotasaude.app").nil? }
  let!(:prior_feature) do
    existing = City.find_by(slug: TEST_CITY_A.slug)
    CityFeature.find_by(city_id: existing.id, key: "ledi_export")&.slice(:enabled) if existing
  end
  let!(:city_state) do
    CityConnection.with(TEST_CITY_A) do
      { profile: CityProfile.current&.slice(:id, :ibge_code),
        credential: IntegrationCredential.exists?(kind: "ledi"),
        admin: User.exists?(email_address: "ledi-admin@cidade.gov.br") }
    end
  end
  let!(:city) { started_at; ledi_ready!(register_test_city!, pec_url: "https://pec.a.test") }
  let(:pec) { FakePec.for("https://pec.a.test") }
  let!(:entry_ids) do
    CityConnection.with(TEST_CITY_A) do
      allow(Ledi::DeliverJob).to receive(:perform_later)
      Array.new(3) do
        Ledi::Enqueue.call(Ledi::Fichas::Synthetic.new(cnes: "1234567", ine: "0000123456",
                                                       professional_cns: "700000000000005", cbo: "225142",
                                                       attended_at: Time.current), city: city).id
      end
    end
  end

  before do
    stub_pec!
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return("já foi recebida")
    allow(Ledi::Observations).to receive(:session_expired_statuses).and_return([ 401 ])
  end

  after do
    3.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    begin
      CityConnection.with(TEST_CITY_A) do
        # Tudo numa transação (DDL do Postgres é transacional): as outras
        # sessões nunca veem o trigger desligado e uma falha volta a ligado.
        guards = { "ledi_outbox" => "ledi_outbox_guard", "domain_events" => "domain_events_guard",
                   "memberships" => "memberships_guard", "users" => "users_no_delete" }
        ApplicationRecord.transaction do
          connection = ApplicationRecord.connection
          connection.execute("SET LOCAL lock_timeout = '5s'")
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
          DomainEvent.where("payload ->> 'outbox_id' IN (?)", entry_ids).delete_all
          LediOutboxEntry.where(id: entry_ids).delete_all
          IntegrationCredential.where(kind: "ledi").delete_all unless city_state[:credential]
          unless city_state[:admin]
            user_ids = User.where(email_address: "ledi-admin@cidade.gov.br").pluck(:id)
            Membership.where(user_id: user_ids).delete_all
            User.where(id: user_ids).delete_all
          end
          if city_state[:profile]
            CityProfile.current&.update_columns(ibge_code: city_state[:profile]["ibge_code"])
          else
            CityProfile.delete_all # singleton: sobra quebraria todo CityProfile.create! posterior
          end
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
        end
      end
    ensure
      begin
        # city.feature_changed (Features.set!) é append-only na plataforma.
        AuditCleanup.delete_platform_events!(
          "name = 'city.feature_changed' AND payload->>'city_id' = $1 AND occurred_at >= $2",
          city.id, started_at.utc.iso8601(6)
        )
      ensure
        if created_city
          CityFeature.where(city_id: city.id).delete_all
          city.destroy
        else
          City.where(id: city.id).update_all(prior_city.to_h.symbolize_keys)
          if prior_feature
            CityFeature.where(city_id: city.id, key: "ledi_export").update_all(prior_feature.to_h.symbolize_keys)
          else
            CityFeature.where(city_id: city.id, key: "ledi_export").delete_all
          end
        end
        Maintainer.where(email_address: "ledi-mantenedor@rotasaude.app").destroy_all if created_maintainer
      end
    end
  end

  def statuses = CityConnection.with(TEST_CITY_A) { LediOutboxEntry.where(id: entry_ids).pluck(:status) }

  it "duas execuções concorrentes enviam cada ficha uma única vez" do
    locked = Queue.new
    holder = nil
    original = LediOutboxEntry.method(:mark_sending)
    allow(LediOutboxEntry).to receive(:mark_sending) do |ids|
      if Thread.current == holder
        locked << true
        release.pop(timeout: 10)
      end
      original.call(ids)
    end

    threads << (holder = Thread.new { described_class.perform_now })
    locked.pop(timeout: 5) or raise "a primeira execução não travou as linhas"

    threads << second = Thread.new { described_class.perform_now }
    expect(second.join(5)).to be(second) # SKIP LOCKED: não espera, não envia
    expect(pec.deliveries).to be_empty

    release << true
    expect(holder.join(5)).to be(holder)
    expect(statuses).to all(eq("accepted"))
    expect(pec.deliveries.map { |d| d[:filename] }.uniq.size).to eq(3)
    expect(pec.deliveries.size).to eq(3)
  end

  # Review Focus 1: o processo caiu depois do POST (o PEC tem a ficha) e antes
  # do UPDATE. A linha fica sending; passados 10 min, volta a pending e o
  # reenvio do mesmo uuid recebe a duplicidade observada — vira accepted.
  # R22: depende de duplicate_after_accept (marker nulo/provisório em
  # pec_observations.yml) — rotasaude/api#41 (go-live gate, provisório).
  it "sending parado volta a pending e o reenvio duplicado vira accepted" do
    CityConnection.with(TEST_CITY_A) do
      LediOutboxEntry.where(id: entry_ids).update_all(status: "sending", updated_at: 11.minutes.ago,
                                                     first_attempt_at: 11.minutes.ago)
    end
    pec.delivery_replies = Array.new(3) { [ 400, "A ficha já foi recebida." ] }
    described_class.perform_now
    expect(statuses).to all(eq("accepted"))
  end
end
