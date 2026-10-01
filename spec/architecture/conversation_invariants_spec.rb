require "rails_helper"

# Invariantes de fechamento do Módulo 02 (Conversação) — ver
# docs/modulos/02--conversacao.md, "Critério de fechamento". O canal do
# cidadão é a web (wpda, ADR 0017); o WhatsApp foi descontinuado. Exemplos
# pequenos, um grupo por invariante; a cobertura a fundo mora nos specs de
# origem (spec/commands/citizens/*, spec/commands/give_consent_channel_spec.rb,
# spec/commands/revoke_consent_spec.rb).
RSpec.describe "Conversation invariants (module 02 closing criteria)" do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:terminal_states) { %w[revoked abandoned completed declined cancelled] }

  def start(version: Consents.current_version)
    Citizens::StartConversation.call(citizen: citizen, consent_version: version, session_id: "sess-inv")
  end

  def publish_new_term!
    ConsentTerm.create!(version: (Consents.current_version.to_i + 1).to_s, body: "Termo novo", published_at: Time.current)
  end

  def attempt(&block)
    ApplicationRecord.transaction(requires_new: true, &block)
  end

  describe "1. terminal is terminal" do
    it "the terminal states are exactly the non-active ones" do
      expect(Conversation.states.keys - Conversation::ACTIVE_STATES).to match_array(terminal_states)
    end

    it "a terminal conversation never goes back to an active state" do
      terminal_states.each do |terminal|
        Conversation::ACTIVE_STATES.each do |active|
          conversation = Conversation.create!(phone: citizen.phone, state: terminal, channel: "web", citizen: citizen)
          expect { conversation.update!(state: active) }
            .to raise_error(ActiveRecord::RecordInvalid), "#{terminal} → #{active} should be refused"
        end
      end
    end

    it "the only way out of a terminal state is revocation (LGPD: revoke at any time)" do
      (terminal_states - %w[revoked]).each do |terminal|
        (terminal_states - [ terminal, "revoked" ]).each do |other|
          conversation = Conversation.create!(phone: citizen.phone, state: terminal, channel: "web", citizen: citizen)
          expect { conversation.update!(state: other) }
            .to raise_error(ActiveRecord::RecordInvalid), "#{terminal} → #{other} should be refused"
        end
        conversation = Conversation.create!(phone: citizen.phone, state: terminal, channel: "web", citizen: citizen)
        expect { conversation.update!(state: :revoked) }.not_to raise_error
      end
    end

    it "a citizen can revoke after completing the triage" do
      conversation = start.payload[:conversation]
      conversation.update!(state: :completed)

      expect(RevokeConsent.call(conversation: conversation, origin: "web")).to be_ok
      expect(conversation.reload).to be_state_revoked
    end
  end

  describe "2. default-deny: no consent in the current term, no progress" do
    it "does not open a conversation without consent to the current term, and records nothing" do
      result = start(version: (Consents.current_version.to_i + 1).to_s)

      expect(result.reason).to eq(:consent_outdated)
      expect(Conversation.where(citizen: citizen)).to be_empty
      expect(Consent.count).to eq(0)
    end

    it "does not record an answer once the consented term is outdated" do
      triage = start.payload[:triage]
      publish_new_term!

      result = Citizens::SubmitAnswer.call(conversation: triage.conversation, answer: "true", idempotency_key: "k1")

      expect(result.reason).to eq(:no_consent)
      expect(triage.reload.answers).to eq({})
      expect(triage.current_step).to eq("tosse")
    end
  end

  describe "3. re-engagement after a terminal state always opens a new conversation" do
    it "opens a fresh conversation for every terminal state, leaving the old one as it was" do
      terminal_states.each do |terminal|
        old = start.payload[:conversation]
        old.update_columns(state: terminal)

        fresh = start.payload[:conversation]

        expect(fresh).not_to eq(old)
        expect(old.reload.state).to eq(terminal)
      end
    end
  end

  describe "4. consent is versioned and frozen" do
    let!(:consent) { start.payload[:conversation].active_consent }

    it "records the version and the text hash of the term it was given for" do
      expect(consent.version.to_s).to eq(Consents.current_version)
      expect(consent.policy_text_sha).to eq(Consents.policy_text_sha(Consents.current_version))
    end

    it "never rewrites what was consented to, even bypassing the model" do
      { version: 99, policy_text_sha: "x", channel: "whatsapp", given_at: 1.day.ago,
        conversation_id: Conversation.create!(phone: "+5541990000001").id }.each do |column, value|
        expect { attempt { Consent.where(id: consent.id).update_all(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /consents/), "#{column} should be frozen"
      end
    end

    it "is never deleted" do
      expect { attempt { Consent.where(id: consent.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /consents is append-only/)
    end

    it "is revoked once, and the revocation is never undone or moved" do
      consent.revoke!
      expect { attempt { Consent.where(id: consent.id).update_all(revoked_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /already revoked/)
      expect { attempt { Consent.where(id: consent.id).update_all(revoked_at: 1.day.from_now) } }
        .to raise_error(ActiveRecord::StatementInvalid, /already revoked/)
    end

    it "still lets the evidence be re-encrypted (city:rotate_key)" do
      expect { attempt { Consent.where(id: consent.id).update_all(evidence: "recifrado", updated_at: Time.current) } }
        .not_to raise_error
    end

    it "a new term means a new consent row; the old one keeps its version" do
      conversation = consent.conversation
      publish_new_term!

      start(version: Consents.current_version)

      expect(consent.reload.revoked_at).to be_present
      expect(consent.version.to_s).not_to eq(Consents.current_version)
      expect(conversation.reload.active_consent.version.to_s).to eq(Consents.current_version)
    end
  end
end
