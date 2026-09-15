require "rails_helper"

RSpec.describe ResendPendingAlertsJob, type: :job do
  include ActiveJob::TestHelper

  # Mesmo slug/database_url de TEST_CITY_A: with_city(city.slug) reentra o
  # shard que o harness já tem aberto, então DomainEvent/ProcessedEvent
  # criados abaixo na conexão padrão e os escritos pelo with_city dos
  # consumers compartilham a mesma sessão (ver anonymize_revoked_triage_job_spec.rb).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  before { Current.city = TEST_CITY_A }

  def make_event(name: "triage.urgent", occurred_at:, published_at: nil, payload: { "triage_id" => SecureRandom.uuid })
    DomainEvent.create!(name: name, payload: payload, occurred_at: occurred_at, published_at: published_at)
  end

  # ResendPendingAlertsJob prepend EachCityJob (roda por cidade ativa via
  # City.where(status: "active")); chamamos o corpo direto, como
  # purge_domain_events_job_spec.rb já faz, para exercitar o resend isolado na
  # conexão de cidade que o harness já abriu.
  def call_body
    described_class.instance_method(:perform).super_method.bind_call(described_class.new)
  end

  it "redespacha um triage.urgent pending com mais de 5 minutos" do
    old = make_event(occurred_at: 10.minutes.ago)

    expect { call_body }.to have_enqueued_job(AlertMunicipalityJob).with(hash_including(
      event_id: old.id,
      event_name: "triage.urgent",
      city_slug: TEST_CITY_A.slug
    ))
  end

  it "não redespacha um evento pending recente (< 5 minutos)" do
    make_event(occurred_at: 2.minutes.ago)

    expect { call_body }.not_to have_enqueued_job(AlertMunicipalityJob)
  end

  it "não redespacha um evento já publicado" do
    make_event(occurred_at: 10.minutes.ago, published_at: Time.current)

    expect { call_body }.not_to have_enqueued_job(AlertMunicipalityJob)
  end

  it "não redespacha outros nomes de evento" do
    make_event(name: "triage.completed", occurred_at: 10.minutes.ago)

    expect { call_body }.not_to have_enqueued_job(AlertMunicipalityJob)
  end

  it "redespacha vários eventos pendentes e antigos, um a um (find_each)" do
    old_a = make_event(occurred_at: 10.minutes.ago)
    old_b = make_event(occurred_at: 20.minutes.ago)

    call_body

    expect(AlertMunicipalityJob).to have_been_enqueued.with(hash_including(event_id: old_a.id)).exactly(1).times
    expect(AlertMunicipalityJob).to have_been_enqueued.with(hash_including(event_id: old_b.id)).exactly(1).times
  end

  describe "end-to-end (test adapter)" do
    it "redespachar um evento já processado não gera um segundo alerta, e marca published_at" do
      old = make_event(occurred_at: 10.minutes.ago)
      # Simula que AlertMunicipalityJob já tratou este evento (ProcessedEvent
      # já existe) mas o DomainEvent nunca foi marcado — o estado que o bug
      # original deixava, e que fazia o resend job tentar de novo pra sempre.
      CityConnection.with(city) do
        ProcessedEvent.create!(event_id: old.id, consumer: "AlertMunicipalityJob", processed_at: Time.current)
      end

      perform_enqueued_jobs { call_body }

      expect(DispatchMunicipalityAlertJob).not_to have_been_enqueued
      reloaded = CityConnection.with(city) { DomainEvent.find(old.id) }
      expect(reloaded.published_at).to be_present
    end

    it "redespachar um evento nunca processado entrega o alerta e marca published_at" do
      # AlertMailer não tem template de view (achado à parte, reportado
      # separadamente) — stub aqui para exercitar só a cadeia
      # redispatch -> AlertMunicipalityJob -> DispatchMunicipalityAlertJob ->
      # dedup/published_at, sem depender de renderizar o e-mail de verdade.
      delivery = instance_double(ActionMailer::MessageDelivery, deliver_now: true)
      allow(AlertMailer).to receive(:urgent).and_return(delivery)

      recipient_id = nil
      triage_id = nil
      CityConnection.with(city) do
        pd = ProtocolDefinition.create!(name: "resend-demo", version: 1, status: "active", definition: {
          "name" => "resend-demo", "version" => 1, "start_step_id" => "s1",
          "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                        "branches" => { "true" => nil, "false" => nil } } ],
          "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
        })
        convo = Conversation.create!(phone: "+551199", state: "completed")
        triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "resend-demo",
                                status: "completed", answers: {}, tier: "alta", priority: 1,
                                current_step: "s1", completed_at: Time.current)
        triage_id = triage.id
        recipient_id = AlertRecipient.create!(channel: "email", destination: "secretaria@cidade.gov.br",
                                              active: true, escalation_order: 1).id
      end

      old = make_event(occurred_at: 10.minutes.ago, payload: { "triage_id" => triage_id })

      perform_enqueued_jobs { call_body }

      reloaded = CityConnection.with(city) { DomainEvent.find(old.id) }
      expect(reloaded.published_at).to be_present
      dispatched = CityConnection.with(city) do
        ProcessedEvent.exists?(event_id: "alert:#{triage_id}", consumer: "dispatch_alert")
      end
      expect(dispatched).to be(true)
      expect(recipient_id).to be_present
      expect(AlertMailer).to have_received(:urgent).with(hash_including(triage_id: triage_id)).once
    end
  end
end
