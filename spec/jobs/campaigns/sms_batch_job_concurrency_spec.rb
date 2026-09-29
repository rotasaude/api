require "rails_helper"

# Dois SmsBatchJob da mesma campanha ao mesmo tempo (o DueJob reenfileira lote
# encalhado, e a reprogramação das 8h pode coincidir com ele) nunca mandam o
# mesmo SMS duas vezes. Threads reais contra o banco de TEST_CITY_A, sem fixture
# transacional, como em due_job_concurrency_spec.rb: a thread "segura" o lote
# aberto parando dentro da primeira entrega; o after solta tudo e apaga o que
# commitou (campanha enviada, evento e usuário têm trigger contra DELETE,
# desligado só nesta limpeza).
RSpec.describe Campaigns::SmsBatchJob, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let!(:created_city) { City.find_by(slug: TEST_CITY_A.slug).nil? }
  let!(:city_record) { register_test_city! }
  let!(:fixture) do
    CityConnection.with(TEST_CITY_A) do
      campaign = sent_campaign!(sms_enabled: true)
      citizens = Array.new(3) { person!.tap { |p| opt_in!(p) } }
      citizens.each { |c| recipient!(campaign, c) }
      { campaign_id: campaign.id, author_id: campaign.created_by_user_id, citizen_ids: citizens.map(&:id) }
    end
  end

  before do
    stub_const("Campaigns::SmsBatchJob::WINDOW_HOURS", (0...24))
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    begin
      CityConnection.with(TEST_CITY_A) do
        guards = { "campaigns" => "campaigns_frozen_after_send", "domain_events" => "domain_events_guard",
                   "users" => "users_no_delete" }
        ApplicationRecord.transaction do
          connection = ApplicationRecord.connection
          connection.execute("SET LOCAL lock_timeout = '5s'")
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
          CampaignRecipient.where(campaign_id: fixture[:campaign_id]).delete_all
          CitizenContactPreference.where(citizen_id: fixture[:citizen_ids]).delete_all
          Citizen.where(id: fixture[:citizen_ids]).delete_all
          DomainEvent.where("payload ->> 'campaign_id' = ?", fixture[:campaign_id].to_s).delete_all
          Campaign.where(id: fixture[:campaign_id]).delete_all
          User.where(id: fixture[:author_id]).delete_all
          guards.each { |table, trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
        end
      end
    ensure
      city_record.destroy if created_city
    end
  end

  def run_batch = described_class.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: fixture[:campaign_id])
  def statuses = CityConnection.with(TEST_CITY_A) { CampaignRecipient.where(campaign_id: fixture[:campaign_id]).pluck(:sms_status) }
  def batch_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j["job_class"] == described_class.name }

  # A primeira entrega da thread `holder` sinaliza e para até o release; as
  # entregas de qualquer thread ficam registradas (telefone e thread).
  def hold_first_delivery(holder:, signal:, log:)
    allow(SmsGateway).to receive(:deliver).and_wrap_original do |original, **args|
      log << [ args[:phone], Thread.current ]
      if Thread.current == holder.call && !Thread.current[:held]
        Thread.current[:held] = true
        signal << true
        release.pop(timeout: 10)
      end
      original.call(**args)
    end
  end

  it "dois lotes ao mesmo tempo: cada telefone recebe um SMS só" do
    delivering = Queue.new
    log = Queue.new
    holder = nil
    hold_first_delivery(holder: -> { holder }, signal: delivering, log: log)

    threads << (holder = Thread.new { run_batch })
    delivering.pop(timeout: 5) or raise "o primeiro lote não chegou a entregar"

    threads << second = Thread.new { run_batch }
    expect(second.join(5)).to be(second) # não espera o primeiro, e não pega as linhas dele

    release << true
    expect(holder.join(5)).to be(holder)
    phones = Array.new(log.size) { log.pop.first }
    expect(phones.size).to eq(3)
    expect(phones.uniq.size).to eq(3)
    expect(statuses).to eq(%w[sent sent sent])
  end

  it "o segundo lote sai sem entregar nem se reenfileirar: uma cadeia de lotes por campanha" do
    stub_const("Campaigns::SmsBatchJob::BATCH_SIZE", 2)
    delivering = Queue.new
    log = Queue.new
    holder = nil
    hold_first_delivery(holder: -> { holder }, signal: delivering, log: log)

    threads << (holder = Thread.new { run_batch })
    delivering.pop(timeout: 5) or raise "o primeiro lote não chegou a entregar"

    threads << second = Thread.new { run_batch }
    expect(second.join(5)).to be(second)
    expect(log.size).to eq(1)         # só a entrega parada do primeiro lote
    expect(batch_jobs).to be_empty    # o segundo não se reenfileirou

    release << true
    expect(holder.join(5)).to be(holder)
    expect(statuses.tally).to eq("sent" => 2, "pending" => 1)
    expect(batch_jobs.size).to eq(1) # quem continua é o primeiro
  end
end
