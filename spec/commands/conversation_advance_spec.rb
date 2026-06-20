require "rails_helper"

# Cobertura mínima das transições de estado da Conversation.
# Caminho :consented + protocolo cheio é deferido (precisa de setup do motor
# de protocolos + scoring real; testes parciais do motor vivem em outro spec).
RSpec.describe ConversationAdvance do
  let(:muni) { create(:municipality) }

  let(:conversation) do
    Conversation.create!(municipality_id: muni.id, phone: "+5511988888888", state: :greeting)
  end

  let(:inbound) do
    InboundMessage.create!(
      message_id: "wamid.#{SecureRandom.hex(6)}",
      from: "+5511988888888",
      kind: "text",
      raw: { "type" => "text", "text" => { "body" => raw_body } }.to_json,
      municipality_id: muni.id
    )
  end

  let(:raw_body) { "qualquer coisa" }

  around do |ex|
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ex.run
      raise ActiveRecord::Rollback
    end
  end

  after { Current.reset }

  describe "estado :greeting" do
    let(:raw_body) { "oi" }

    it "responde com greeting e move para awaiting_consent" do
      result = described_class.call(conversation: conversation, inbound: inbound)
      expect(result.reply).to eq(ConversationAdvance::GREETING_TEXT)
      expect(conversation.reload.state).to eq("awaiting_consent")
    end
  end

  describe "estado :awaiting_consent" do
    before { conversation.update!(state: :awaiting_consent) }

    context "com resposta de consentimento (sim)" do
      let(:raw_body) { "sim" }

      it "sem protocolo ativo → reply NO_PROTOCOL_TEXT (consent foi registrado)" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply).to eq(ConversationAdvance::NO_PROTOCOL_TEXT)
        expect(conversation.reload.state).to eq("consented")
        expect(conversation.consents.count).to eq(1)
      end
    end

    context "com resposta negativa (não)" do
      let(:raw_body) { "não" }

      it "responde com texto de revogação e move conversation para revoked" do
        conversation.consents.create!(
          version: Consents.current_version(muni.id),
          policy_text_sha: Consents.policy_text_sha(Consents.current_version(muni.id)),
          given_at: 1.minute.ago,
          channel: "whatsapp",
          evidence: { text: "sim" }
        )
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply).to eq(ConversationAdvance::CONSENT_REVOKED_TEXT)
        expect(conversation.reload.state).to eq("revoked")
      end
    end

    context "com texto que não é claramente sim/não" do
      let(:raw_body) { "talvez" }

      it "responde com prompt re-perguntando consent" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply).to eq(ConversationAdvance::CONSENT_PROMPT_TEXT)
        expect(conversation.reload.state).to eq("awaiting_consent")
      end
    end
  end

  describe "estado :revoked" do
    before { conversation.update!(state: :revoked) }

    it "não responde (terminal)" do
      result = described_class.call(conversation: conversation, inbound: inbound)
      expect(result.reply).to be_nil
    end
  end

  describe "extração de texto do payload" do
    let(:raw_body) { "" }

    it "lida com raw inválido sem levantar" do
      inbound.update_column(:raw, "lixo não-JSON")
      result = described_class.call(conversation: conversation, inbound: inbound)
      # greeting state → reply é o greeting independente do texto extraído.
      expect(result.reply).to eq(ConversationAdvance::GREETING_TEXT)
    end
  end
end
