require "rails_helper"

RSpec.describe ProcessInboundMessageJob, type: :job do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs }

  # Same slug/database_url as TEST_CITY_A so the job's with_city(city_slug)
  # re-enters the shard the harness already has open — fixtures below (seeded
  # on the default connection) and the job's own connection then share one
  # session/transaction.
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  # Cria conversa (estado dado) + inbound (corpo dado) na cidade do teste.
  # Retorna [conversation_id, inbound_id].
  def seed(state:, body:, message_id:)
    convo = Conversation.create!(phone: "+5511990001", state: state)
    inbound = InboundMessage.create!(
      message_id: message_id, from: "+5511990001", kind: "text",
      raw: { "type" => "text", "text" => { "body" => body } }.to_json
    )
    [convo.id, inbound.id]
  end

  it "advances the conversation, enqueues the reply, and marks processed_at — atomically" do
    convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.h1")

    expect {
      described_class.new.perform(inbound_id, city_slug: city.slug)
    }.to have_enqueued_job(SendWhatsappJob).exactly(:once).with(hash_including(city_slug: city.slug))

    expect(Conversation.find(convo_id).state).to eq("awaiting_consent")
    expect(InboundMessage.find(inbound_id).processed_at).to be_present
  end

  it "is idempotent: a second run does not re-advance or re-enqueue" do
    convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.i1")

    described_class.new.perform(inbound_id, city_slug: city.slug)
    expect(ConversationAdvance).not_to receive(:call)

    expect {
      described_class.new.perform(inbound_id, city_slug: city.slug)
    }.not_to have_enqueued_job(SendWhatsappJob)

    expect(Conversation.find(convo_id).state).to eq("awaiting_consent")
  end

  it "does not enqueue or mark processed when ConversationAdvance raises (rollback)" do
    convo_id, inbound_id = seed(state: "greeting", body: "oi", message_id: "wamid.r1")
    allow(ConversationAdvance).to receive(:call).and_raise(RuntimeError, "boom")

    expect {
      described_class.new.perform(inbound_id, city_slug: city.slug)
    }.to raise_error(RuntimeError)

    expect(SendWhatsappJob).not_to have_been_enqueued
    expect(InboundMessage.find(inbound_id).processed_at).to be_nil
    expect(Conversation.find(convo_id).state).to eq("greeting")
  end

  it "re-onboards when the phone's only conversation is terminal: fresh greeting + reply + processed" do
    old_convo_id, inbound_id = seed(state: "revoked", body: "oi", message_id: "wamid.reonb1")

    expect {
      described_class.new.perform(inbound_id, city_slug: city.slug)
    }.to have_enqueued_job(SendWhatsappJob).exactly(:once)

    expect(InboundMessage.find(inbound_id).processed_at).to be_present
    active = Conversation.where(phone: "+5511990001", state: "awaiting_consent").first
    expect(active).to be_present
    expect(active.id).not_to eq(old_convo_id)
    expect(Conversation.find(old_convo_id).state).to eq("revoked")
  end

  it "marks processed and enqueues nothing when ConversationAdvance yields no reply" do
    _convo_id, inbound_id = seed(state: "consented", body: "oi", message_id: "wamid.nr1")
    allow(ConversationAdvance).to receive(:call).and_return(ConversationAdvance::Result.new(reply: nil))

    expect {
      described_class.new.perform(inbound_id, city_slug: city.slug)
    }.not_to have_enqueued_job(SendWhatsappJob)

    expect(InboundMessage.find(inbound_id).processed_at).to be_present
  end

  # R44: the queue no longer shares the city's database, so an in-transaction
  # enqueue is not atomic with the state advance — SendWhatsappJob inherits
  # ApplicationJob's after-commit deferral (R40); idempotency_key covers retries.
  it "SendWhatsappJob defers its enqueue to the city commit (inherits ApplicationJob, R44)" do
    expect(SendWhatsappJob.enqueue_after_transaction_commit).to be(true)
  end
end
