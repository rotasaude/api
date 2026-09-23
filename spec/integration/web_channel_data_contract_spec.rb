require "rails_helper"

# O teste que prova o objetivo do spec 2026-09-22-web-citizen-channel: a mesma
# triagem feita pela web e pelo WhatsApp produz os MESMOS registros e eventos.
# Só consents.channel/evidence e conversations.channel/citizen_id podem diferir.
RSpec.describe "Web channel data contract" do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  def whatsapp_triage(answers)
    phone = "+5541977776666"
    conversation = Conversation.for(phone)
    (["oi", "sim"] + answers).each do |text|
      inbound = InboundMessage.create!(
        message_id: "wamid.#{SecureRandom.hex(6)}", from: phone, kind: "text",
        raw: { "type" => "text", "text" => { "body" => text } }.to_json
      )
      ConversationAdvance.call(conversation: conversation.reload, inbound: inbound)
    end
    conversation.reload.triages.sole
  end

  def web_triage(answers)
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload
    answers.each_with_index do |answer, i|
      Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: answer, idempotency_key: "k#{i}")
    end
    started[:triage].reload
  end

  def triage_contract(triage)
    triage.attributes.slice("status", "tier", "priority", "answers", "outcome", "protocol_name", "protocol_definition_id")
  end

  def consent_contract(triage)
    triage.conversation.consents.sole.attributes.slice("version", "policy_text_sha", "revoked_at")
  end

  def events_contract(triage)
    DomainEvent.where("payload->>'triage_id' = ?", triage.id).order(:name)
               .map { |e| [e.name, e.payload.except("triage_id")] }
  end

  [%w[true true], %w[true false], %w[false]].each do |answers|
    it "respostas #{answers.inspect}: mesma triagem, mesmo consentimento, mesmos eventos" do
      whatsapp = whatsapp_triage(answers)
      web = web_triage(answers)

      expect(triage_contract(web)).to eq(triage_contract(whatsapp))
      expect(consent_contract(web)).to eq(consent_contract(whatsapp))
      expect(events_contract(web)).to eq(events_contract(whatsapp))
      expect(DomainEvent.where(name: "consent.given").count).to eq(2)

      expect(whatsapp.conversation).to be_state_completed
      expect(web.conversation).to be_state_completed
      expect(web.conversation.consents.sole.channel).to eq("web")
      expect(whatsapp.conversation.consents.sole.channel).to eq("whatsapp")
    end
  end
end
