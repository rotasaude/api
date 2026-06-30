require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe ProcessInboundMessageJob, type: :job do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  before { clean_admin_tables; clear_enqueued_jobs }
  after  { clean_admin_tables }

  # Cria muni + conversa (estado dado) + inbound (corpo dado) via conexão admin.
  # Retorna [muni_id, conversation_id, inbound_id].
  def seed(state:, body:, message_id:)
    ids = nil
    as_admin do
      muni = Municipality.create!(name: "PIMJ City", slug: "pimj-#{message_id}", ibge_code: "3500030")
      convo = Conversation.create!(municipality_id: muni.id, phone: "+5511990001", state: state)
      inbound = InboundMessage.create!(
        message_id: message_id, from: "+5511990001", kind: "text",
        raw: { "type" => "text", "text" => { "body" => body } }.to_json,
        municipality_id: muni.id
      )
      ids = [muni.id, convo.id, inbound.id]
    end
    ids
  end

  it "advances the conversation, enqueues the reply, and marks processed_at — atomically" do
    muni_id, convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.h1")

    expect {
      described_class.new.perform(inbound_id, municipality_id: muni_id)
    }.to have_enqueued_job(SendWhatsappJob).exactly(:once)

    expect(as_admin { Conversation.find(convo_id).state }).to eq("awaiting_consent")
    expect(as_admin { InboundMessage.find(inbound_id).processed_at }).to be_present
  end

  it "is idempotent: a second run does not re-advance or re-enqueue" do
    muni_id, convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.i1")

    described_class.new.perform(inbound_id, municipality_id: muni_id)
    expect(ConversationAdvance).not_to receive(:call)

    expect {
      described_class.new.perform(inbound_id, municipality_id: muni_id)
    }.not_to have_enqueued_job(SendWhatsappJob)

    expect(as_admin { Conversation.find(convo_id).state }).to eq("awaiting_consent")
  end

  it "does not enqueue or mark processed when ConversationAdvance raises (rollback)" do
    muni_id, convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.r1")
    allow(ConversationAdvance).to receive(:call).and_raise(RuntimeError, "boom")

    expect {
      described_class.new.perform(inbound_id, municipality_id: muni_id)
    }.to raise_error(RuntimeError)

    expect(SendWhatsappJob).not_to have_been_enqueued
    expect(as_admin { InboundMessage.find(inbound_id).processed_at }).to be_nil
    expect(as_admin { Conversation.find(convo_id).state }).to eq("greeting")
  end

  it "marks processed and enqueues nothing when there is no reply" do
    muni_id, convo_id, inbound_id = seed(state: "revoked", body: "oi", message_id: "wamid.n1")

    expect {
      described_class.new.perform(inbound_id, municipality_id: muni_id)
    }.not_to have_enqueued_job(SendWhatsappJob)

    expect(as_admin { InboundMessage.find(inbound_id).processed_at }).to be_present
  end

  it "SendWhatsappJob enqueues within the transaction (no after-commit deferral)" do
    expect(SendWhatsappJob.enqueue_after_transaction_commit).to be(false)
  end
end
