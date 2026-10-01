require "rails_helper"

RSpec.describe NotifyCitizenJob do
  include ActiveJob::TestHelper

  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def protocol
    @protocol ||= ProtocolDefinition.create!(
      name: "notify-spec", version: 1, status: "active",
      definition: { "name" => "notify-spec", "version" => 1, "start_step_id" => "s1",
                    "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                  "branches" => { "true" => nil, "false" => nil } }] }
    )
  end

  def triage_for(conversation)
    Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: "notify-spec",
                   status: "completed", tier: "alta", priority: 1, completed_at: Time.current,
                   outcome: { "trail" => [] })
  end

  def snapshot_for(triage)
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: triage, protocol_definition: protocol, outcome: { "tier" => "alta" },
                           payload: { "tier" => "alta" }, token: token,
                           signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)
  end

  def completed_triage(conversation)
    triage_for(conversation).tap { |triage| snapshot_for(triage) }
  end

  def whatsapp_conversation = Conversation.create!(phone: "+5541998765432", state: :completed)

  def web_conversation
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    Conversation.create!(phone: citizen.phone, state: :completed, channel: "web", citizen: citizen)
  end

  it "no WhatsApp, manda o link do relatório" do
    triage = completed_triage(whatsapp_conversation)
    expect { described_class.new.handle(triage_id: triage.id) }.to have_enqueued_job(SendWhatsappJob)
  end

  it "na web, não manda nada: o link aparece na tela" do
    triage = completed_triage(web_conversation)
    expect { described_class.new.handle(triage_id: triage.id) }.not_to have_enqueued_job(SendWhatsappJob)
  end

  # F-04.7: GenerateReportJob (fila reports) e NotifyCitizenJob (fila default)
  # saem do MESMO triage.completed, sem ordem garantida. Se este rodar antes do
  # snapshot existir, não pode consumir o evento: o ProcessedEvent gravado pelo
  # IdempotentConsumer faria qualquer nova entrega virar no-op e o link do
  # cidadão do WhatsApp sumiria em silêncio. Passa pelo perform completo
  # (with_city + dedup + retry_on), não só pelo #handle.
  describe "quando o snapshot ainda não existe (corrida com GenerateReportJob)" do
    let!(:city) { create(:city, slug: TEST_CITY_A.slug, database_url: city_database_url("rota_saude_test_city_a")) }
    let(:event) { DomainEvent.create!(name: "triage.completed", payload: {}, occurred_at: Time.current) }

    def deliver(triage)
      described_class.perform_now(event_id: event.id, event_name: "triage.completed", city_slug: city.slug,
                                  payload: { "triage_id" => triage.id })
    end

    def processed?(event_id) = ProcessedEvent.exists?(event_id: event_id, consumer: described_class.name)

    it "não consome o evento: sem ProcessedEvent, sem mensagem, e o job volta para a fila" do
      triage = triage_for(whatsapp_conversation)

      expect { deliver(triage) }.to have_enqueued_job(described_class)
        .with(event_id: event.id, event_name: "triage.completed", city_slug: city.slug,
              payload: { "triage_id" => triage.id })

      expect(processed?(event.id)).to be(false)
      expect(event.reload.published_at).to be_nil
      expect(SendWhatsappJob).not_to have_been_enqueued
    end

    it "manda o link uma única vez quando o snapshot aparece antes da nova tentativa" do
      triage = triage_for(whatsapp_conversation)
      deliver(triage)
      snapshot = snapshot_for(triage)

      deliver(triage)
      deliver(triage) # reentrega depois do sucesso: dedup

      sent = enqueued_jobs.select { |job| job["job_class"] == "SendWhatsappJob" }
      expect(sent.size).to eq(1)
      expect(sent.first.dig("arguments", 0, "message").to_s).to include(snapshot.token)
      expect(processed?(event.id)).to be(true)
      expect(event.reload.published_at).to be_present
    end

    it "na web continua sem mandar nada e consome o evento, mesmo sem snapshot" do
      triage = triage_for(web_conversation)

      expect { deliver(triage) }.not_to have_enqueued_job(described_class)
      expect(SendWhatsappJob).not_to have_been_enqueued
      expect(processed?(event.id)).to be(true)
    end
  end

  it "pula uma triagem anonimizada: sem mensagem e sem SnapshotNotReady (ADR 0026)" do
    triage = triage_for(whatsapp_conversation)
    triage.update_columns(anonymized_at: Time.current, outcome: nil, tier: nil, priority: nil)

    expect { described_class.new.handle(triage_id: triage.id) }.not_to raise_error
    expect(SendWhatsappJob).not_to have_been_enqueued
  end
end
