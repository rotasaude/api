require "rails_helper"

# Spec §9.1: "duas execuções concorrentes não enviam em dobro". Threads reais
# contra o banco real de TEST_CITY_A (sem fixture transacional), como em
# spec/models/health_unit_lock_spec.rb. A thread "segura" a transação aberta
# (com a linha da campanha travada) parando num gancho dentro dela; o after
# solta tudo e apaga o que commitou (o trigger só deixa apagar rascunho, então
# ele é desligado só nesta limpeza).
RSpec.describe Campaigns::DueJob, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let!(:created_city) { City.find_by(slug: TEST_CITY_A.slug).nil? }
  let!(:city_record) { register_test_city! }
  let!(:author) do
    CityConnection.with(TEST_CITY_A) do
      User.create!(email_address: "conc-#{SecureRandom.hex(4)}@cidade.gov.br", password: "senha-segura-123")
    end
  end
  let!(:campaign_id) do
    CityConnection.with(TEST_CITY_A) do
      campaign = Campaign.create!(title: "Concorrência", body: "Texto da campanha.", audience: city_audience,
                                  created_by_user: author)
      campaign.update_columns(status: "scheduled", send_at: 1.minute.ago)
      campaign.id
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    begin
      CityConnection.with(TEST_CITY_A) do
        # Campanha (só rascunho apaga), evento de domínio e usuário são
        # append-only: o dono das tabelas desliga o trigger só nesta limpeza.
        # Tudo numa transação (DDL do Postgres é transacional): as outras
        # sessões nunca veem o trigger desligado e uma falha volta a ligado.
        guards = { "campaigns" => "campaigns_frozen_after_send", "domain_events" => "domain_events_guard",
                   "users" => "users_no_delete" }
        ApplicationRecord.transaction do
          connection = ApplicationRecord.connection
          connection.execute("SET LOCAL lock_timeout = '5s'")
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
          DomainEvent.where("payload ->> 'campaign_id' = ?", campaign_id.to_s).delete_all
          Campaign.where(id: campaign_id).delete_all
          User.where(id: author.id).delete_all
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
        end
      end
    ensure
      city_record.destroy if created_city
    end
  end

  def status = CityConnection.with(TEST_CITY_A) { Campaign.find(campaign_id).status }
  def dispatches = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j["job_class"] == "Campaigns::DispatchJob" }

  # Faz `target.method` parar (uma vez, só na thread `holder`) depois de sinalizar
  # que a transação com a linha travada está aberta.
  def hold_at(target, method, holder:, signal:)
    original = target.method(method)
    allow(target).to receive(method) do |*args, **kwargs, &blk|
      if Thread.current == holder.call
        signal << true
        release.pop(timeout: 10)
      end
      original.call(*args, **kwargs, &blk)
    end
  end

  it "duas execuções concorrentes soltam a campanha uma única vez" do
    locked = Queue.new
    holder = nil
    hold_at(Campaigns::DispatchJob, :perform_later, holder: -> { holder }, signal: locked)

    threads << (holder = Thread.new { described_class.perform_now })
    locked.pop(timeout: 5) or raise "a primeira execução não travou a linha"

    threads << second = Thread.new { described_class.perform_now }
    expect(second.join(5)).to be(second) # SKIP LOCKED: não espera, não solta
    expect(status).to eq("scheduled")    # a primeira ainda não commitou

    release << true
    expect(holder.join(5)).to be(holder)
    expect(status).to eq("sending")
    expect(dispatches.size).to eq(1)
  end

  it "o DueJob não solta a campanha que o Cancel está cancelando (fica cancelada, sem dispatch)" do
    locked = Queue.new
    holder = nil
    hold_at(DomainEvents, :publish, holder: -> { holder }, signal: locked)

    threads << (holder = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        Campaigns::Cancel.call(campaign: Campaign.find(campaign_id), by: author)
      end
    end)
    locked.pop(timeout: 5) or raise "o Cancel não travou a linha"

    threads << due = Thread.new { described_class.perform_now }
    expect(due.join(5)).to be(due)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(status).to eq("cancelled")
    expect(dispatches).to be_empty
  end

  it "o Cancel que espera o DueJob relê sending e recusa (sem cancelar o que já saiu)" do
    locked = Queue.new
    holder = nil
    hold_at(Campaigns::DispatchJob, :perform_later, holder: -> { holder }, signal: locked)

    threads << (holder = Thread.new { described_class.perform_now })
    locked.pop(timeout: 5) or raise "o DueJob não travou a linha"

    result = Queue.new
    threads << canceller = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        result << Campaigns::Cancel.call(campaign: Campaign.find(campaign_id), by: author)
      end
    end
    expect(wait_for_lock_wait).to be(true) # o Cancel está parado no FOR UPDATE

    release << true
    holder.join(5)
    canceller.join(5)
    outcome = result.pop(timeout: 5)
    expect([ outcome.ok?, outcome.reason ]).to eq([ false, :invalid_transition ])
    expect(status).to eq("sending")
    expect(dispatches.size).to eq(1)
  end
end
