require "rails_helper"

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

  let(:protocol_definition_hash) do
    {
      "name" => ConversationAdvance::DEFAULT_PROTOCOL_NAME,
      "version" => 1,
      "start_step_id" => "tosse",
      "steps" => [
        {
          "id" => "tosse",
          "prompt" => "Você está com tosse?",
          "answer_type" => "boolean",
          "branches" => { "true" => "febre", "false" => nil },
          "weights" => { "true" => 1, "false" => 0 }
        },
        {
          "id" => "febre",
          "prompt" => "Está com febre alta?",
          "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil },
          "weights" => { "true" => 5, "false" => 0 }
        }
      ],
      "scoring" => {
        "type" => "weighted",
        "thresholds" => { "baixa" => 0 },
        "priority_map" => { "baixa" => 9 }
      }
    }
  end

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

  after { Current.reset; Rails.cache.clear }

  describe "estado :greeting" do
    let(:raw_body) { "oi" }

    it "responde com greeting em botões e move para awaiting_consent" do
      result = described_class.call(conversation: conversation, inbound: inbound)
      expect(result.reply.body).to eq(I18n.t("conversation_advance.greeting"))
      expect(result.reply.kind).to eq(:buttons)
      expect(result.reply.options.map { |o| o[:id] }).to eq(%w[consent_give consent_revoke])
      expect(conversation.reload.state).to eq("awaiting_consent")
    end
  end

  describe "estado :awaiting_consent" do
    before { conversation.update!(state: :awaiting_consent) }

    context "com sim e sem protocolo ativo" do
      let(:raw_body) { "sim" }

      it "reply NO_PROTOCOL_TEXT (consent foi registrado)" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply.body).to eq(I18n.t("conversation_advance.no_protocol"))
        expect(conversation.reload.state).to eq("consented")
        expect(conversation.consents.count).to eq(1)
      end
    end

    context "com sim e protocolo ativo" do
      let(:raw_body) { "sim" }

      let!(:protocol_definition) do
        ProtocolDefinition.create!(
          municipality_id: muni.id,
          name: ConversationAdvance::DEFAULT_PROTOCOL_NAME,
          version: 1,
          status: "active",
          definition: protocol_definition_hash
        )
      end

      it "registra consent, inicia triage e responde com prompt do primeiro step" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply.body).to eq(I18n.t("conversation_advance.triage_start", prompt: "Você está com tosse?"))
        expect(result.reply.kind).to eq(:buttons)
        expect(result.reply.options.map { |o| o[:id] }).to eq(%w[true false])
        expect(conversation.reload.state).to eq("consented")
        expect(conversation.triages.status_in_progress.count).to eq(1)
        expect(conversation.triages.first.current_step).to eq("tosse")
      end
    end

    context "com não" do
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
        expect(result.reply.body).to eq(I18n.t("conversation_advance.consent_revoked"))
        expect(conversation.reload.state).to eq("revoked")
      end
    end

    context "com texto unknown" do
      let(:raw_body) { "talvez" }

      it "responde com prompt re-perguntando consent em botões" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply.body).to eq(I18n.t("conversation_advance.consent_prompt"))
        expect(result.reply.kind).to eq(:buttons)
        expect(result.reply.options.map { |o| o[:id] }).to eq(%w[consent_give consent_revoke])
        expect(conversation.reload.state).to eq("awaiting_consent")
      end
    end

    context "quando toca o botão Sim (id consent_give)" do
      let(:raw_body) { "consent_give" }

      it "registra consent e move para consented" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(conversation.reload.state).to eq("consented")
        expect(conversation.consents.count).to eq(1)
      end
    end

    context "quando toca o botão Não (id consent_revoke)" do
      let(:raw_body) { "consent_revoke" }

      it "revoga e move para revoked" do
        conversation.consents.create!(
          version: Consents.current_version(muni.id),
          policy_text_sha: Consents.policy_text_sha(Consents.current_version(muni.id)),
          given_at: 1.minute.ago,
          channel: "whatsapp",
          evidence: { text: "sim" }
        )
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply.body).to eq(I18n.t("conversation_advance.consent_revoked"))
        expect(conversation.reload.state).to eq("revoked")
      end
    end
  end

  describe "estado :consented (fluxo com motor real)" do
    let!(:protocol_definition) do
      ProtocolDefinition.create!(
        municipality_id: muni.id,
        name: ConversationAdvance::DEFAULT_PROTOCOL_NAME,
        version: 1,
        status: "active",
        definition: protocol_definition_hash
      )
    end

    let!(:consent) do
      conversation.consents.create!(
        version: Consents.current_version(muni.id),
        policy_text_sha: Consents.policy_text_sha(Consents.current_version(muni.id)),
        given_at: 1.minute.ago,
        channel: "whatsapp",
        evidence: { text: "sim" }
      )
    end

    before { conversation.update!(state: :consented) }

    context "resposta intermediária (não-terminal)" do
      let(:raw_body) { "true" }

      it "avança para próximo step e responde com prompt do próximo" do
        result = described_class.call(conversation: conversation, inbound: inbound)
        expect(result.reply.body).to eq(I18n.t("conversation_advance.triage_next", prompt: "Está com febre alta?"))
        expect(result.reply.kind).to eq(:buttons)
        triage = conversation.triages.status_in_progress.first
        expect(triage.current_step).to eq("febre")
        expect(triage.answers).to eq("tosse" => "true")
      end
    end

    context "resposta terminal" do
      let(:raw_body) { "true" }

      it "completa a triage e responde nil (event-driven dali)" do
        # avança "tosse" → "febre"
        described_class.call(conversation: conversation, inbound: inbound)

        # 2ª chamada na step "febre" — completa
        next_inbound = InboundMessage.create!(
          message_id: "wamid.#{SecureRandom.hex(6)}",
          from: "+5511988888888",
          kind: "text",
          raw: { "type" => "text", "text" => { "body" => "true" } }.to_json,
          municipality_id: muni.id
        )

        result = described_class.call(conversation: conversation, inbound: next_inbound)
        expect(result.reply).to be_nil
        triage = conversation.triages.first
        expect(triage.status).to eq("completed")
        expect(triage.tier).to eq("baixa")
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
      expect(result.reply.body).to eq(I18n.t("conversation_advance.greeting"))
    end
  end
end
