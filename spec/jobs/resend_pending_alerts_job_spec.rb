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

  # Cria uma triage real + um destinatário ativo, para que -- se o dedup do
  # AlertMunicipalityJob/DispatchMunicipalityAlertJob for contornado por um
  # bug -- a cadeia completa consiga mesmo assim rodar até tentar entregar um
  # segundo e-mail (I1 fix round: sem isto, um bypass de dedup só estouraria
  # em Triage.find, e o teste ficaria vermelho por um motivo incidental, não
  # pela asserção que importa).
  def create_triage_and_recipient!(completed_at: Time.current)
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
                              current_step: "s1", completed_at: completed_at)
      AlertRecipient.create!(channel: "email", destination: "secretaria@cidade.gov.br",
                             active: true, escalation_order: 1)
      triage
    end
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

  it "não redespacha um evento pending com mais de 24 horas" do
    # I2 (fix round 1): DomainEvent sobrevive 12 meses e ProcessedEvent (o
    # dedup) só 60 dias -- sem teto, o primeiro run depois do deploy
    # redespacharia tudo que ficou pending nesse intervalo inteiro, de uma
    # vez. 24h fica bem dentro da janela de dedup.
    make_event(occurred_at: 25.hours.ago)

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
    it "redespachar um evento já processado não gera um segundo alerta, não cria dedup row novo, e marca published_at" do
      triage = create_triage_and_recipient!
      old = make_event(occurred_at: 10.minutes.ago, payload: { "triage_id" => triage.id })
      # Simula que AlertMunicipalityJob já tratou este evento (ProcessedEvent
      # já existe) mas o DomainEvent nunca foi marcado -- o estado que o bug
      # original deixava, e que fazia o resend job tentar de novo pra sempre.
      CityConnection.with(city) do
        ProcessedEvent.create!(event_id: old.id, consumer: "AlertMunicipalityJob", processed_at: Time.current)
      end

      deliveries_before = ActionMailer::Base.deliveries.count

      # I1 (fix round 1): `not_to have_been_enqueued` dentro de
      # perform_enqueued_jobs nunca falharia -- um job performado nunca entra
      # em enqueued_jobs (fica só em performed_jobs), então a asserção
      # original passava mesmo se o dedup fosse contornado. `have_been_performed`
      # olha performed_jobs de fato, e as duas asserções de efeito (nenhum
      # dedup row novo de dispatch_alert, nenhum e-mail novo) confirmam que
      # nada rodou de verdade.
      perform_enqueued_jobs { call_body }

      expect(DispatchMunicipalityAlertJob).not_to have_been_performed
      dispatch_alert_rows = CityConnection.with(city) { ProcessedEvent.where(consumer: "dispatch_alert").count }
      expect(dispatch_alert_rows).to eq(0)
      expect(ActionMailer::Base.deliveries.count).to eq(deliveries_before)
      reloaded = CityConnection.with(city) { DomainEvent.find(old.id) }
      expect(reloaded.published_at).to be_present
    end

    it "redespachar um evento nunca processado entrega o alerta de verdade (template real) e marca published_at" do
      # completed_at bem no passado: se AlertMunicipalityJob usasse
      # Time.current (bug do item "Check") em vez do completed_at real da
      # triage, o e-mail mostraria a data de hoje, não a de dois dias atrás.
      triage = create_triage_and_recipient!(completed_at: 2.days.ago)
      old = make_event(occurred_at: 10.minutes.ago, payload: { "triage_id" => triage.id })

      deliveries_before = ActionMailer::Base.deliveries.count

      perform_enqueued_jobs { call_body }

      expect(DispatchMunicipalityAlertJob).to have_been_performed
      reloaded = CityConnection.with(city) { DomainEvent.find(old.id) }
      expect(reloaded.published_at).to be_present
      dispatched = CityConnection.with(city) do
        ProcessedEvent.exists?(event_id: "alert:#{triage.id}", consumer: "dispatch_alert")
      end
      expect(dispatched).to be(true)
      expect(ActionMailer::Base.deliveries.count).to eq(deliveries_before + 1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "secretaria@cidade.gov.br" ])
      expected_date = triage.completed_at.in_time_zone("America/Sao_Paulo").strftime("%d/%m/%Y")
      expect(mail.text_part.body.decoded).to include(expected_date)
    end
  end
end
