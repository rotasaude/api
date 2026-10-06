require "rails_helper"

RSpec.describe Whatsapp::Ingest do
  include ActiveJob::TestHelper
  # Two real, distinct cities (own physical databases) so "landed in the
  # right city" and "the other city got nothing" are two independently
  # provable claims, not a single connected_to(role: :admin) read that today
  # is a silent no-op returning whichever city is currently connected
  # (5c-1: ApplicationRecord IS the primary class, so connected_to(role:
  # :admin) never raises and never routes anywhere else).
  let(:city_a) { create(:city, database_url: city_database_url(TEST_CITY_A_DATABASE)) }
  let(:city_b) { create(:city, database_url: city_database_url(TEST_CITY_B_DATABASE)) }
  let!(:channel) do
    CityChannel.create!(city: city_a, phone_number_id: "PNID123", waba_id: "WABA1",
                        display_phone_number: "+5511999999999", access_token: "tok", active: true)
  end

  let(:payload) do
    {
      "entry" => [{
        "changes" => [{
          "value" => {
            "metadata" => { "phone_number_id" => "PNID123" },
            "messages" => [{ "id" => "wamid.1", "from" => "+551188", "type" => "text", "text" => { "body" => "oi" } }]
          }
        }]
      }]
    }
  end

  it "persists the inbound in the channel's own city, and only there" do
    city_b # force creation so "the other city stayed at zero" is meaningful

    expect {
      described_class.call(payload)
    }.to change { CityConnection.with(city_a) { InboundMessage.count } }.by(1)

    expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
    expect(UnknownChannel.count).to eq(0)

    inbound = CityConnection.with(city_a) { InboundMessage.last }
    expect(inbound.message_id).to eq("wamid.1")
  end

  it "phone_number_id desconhecido vai para unknown_channels (plataforma), sem tocar nenhuma cidade" do
    payload["entry"][0]["changes"][0]["value"]["metadata"]["phone_number_id"] = "PNID_UNKNOWN"

    expect { described_class.call(payload) }.to change(UnknownChannel, :count).by(1)

    expect(CityConnection.with(city_a) { InboundMessage.count }).to eq(0)
    expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
    # Fix round 1 (I2): city_a/city_b are random-slug Cities — their own
    # sessions cannot see a write on a DIFFERENT connection (5c-3 fix round 1
    # harness note in city_test_databases.rb). The harness's own default
    # connection (TEST_CITY_A, opened by the outer around) is a third,
    # separate session that neither check above reads — assert it too, or a
    # stray write there would go unnoticed.
    expect(InboundMessage.count).to eq(0)
  end

  # F-01.4: sem cidade resolvida e servível, falha fechada — nenhuma cidade
  # recebe nada (city_a, city_b e a conexão default do harness).
  describe "fail-closed routing" do
    def expect_nothing_written_anywhere
      expect(CityConnection.with(city_a) { InboundMessage.count }).to eq(0)
      expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
      expect(InboundMessage.count).to eq(0)
    end

    before { city_b } # força criação: "a outra cidade ficou em zero" precisa existir

    it "discards messages for a channel whose city is not servable" do
      city_a.update!(status: "suspended")

      expect {
        described_class.call(payload)
      }.not_to have_enqueued_job(ProcessInboundMessageJob)

      expect_nothing_written_anywhere
      expect(UnknownChannel.count).to eq(0)
    end

    it "discards a change with blank phone_number_id without recording an unknown channel" do
      payload["entry"][0]["changes"][0]["value"]["metadata"]["phone_number_id"] = ""
      missing = { "entry" => [{ "changes" => [{ "value" => { "messages" => payload.dig("entry", 0, "changes", 0, "value", "messages") } }] }] }

      expect {
        described_class.call(payload)
        described_class.call(missing)
      }.not_to have_enqueued_job(ProcessInboundMessageJob)

      expect_nothing_written_anywhere
      expect(UnknownChannel.count).to eq(0)
    end

    # ADR 0017: WhatsApp desligado por cidade = CityChannel inativo. Um número
    # conhecido e desligado não é "número desconhecido mal configurado" — não
    # vai para UnknownChannel, só é descartado e logado.
    it "discards messages for an inactive channel without recording it as unknown" do
      channel.update!(active: false)
      allow(Rails.logger).to receive(:warn).and_call_original

      expect {
        described_class.call(payload)
      }.not_to have_enqueued_job(ProcessInboundMessageJob)

      expect_nothing_written_anywhere
      expect(UnknownChannel.count).to eq(0)
      expect(Rails.logger).to have_received(:warn)
        .with(satisfy { |line|
          line.include?("phone_number_id=PNID123") && line.include?("city=#{city_a.slug}") &&
            !line.include?("+551188") && !line.include?("wamid.1")
        })
    end
  end

  it "reentrega do mesmo wamid não duplica na cidade" do
    described_class.call(payload)
    expect {
      described_class.call(payload)
    }.not_to change { CityConnection.with(city_a) { InboundMessage.count } }
  end

  it "cidade com schema atrasado não grava nada e o resultado sinaliza schema_behind" do
    city_a.update!(schema_version: (CitySchema.expected_version - 1).to_s)

    result = nil

    # M2 (hardening review): the repo's convention for "nothing enqueued" is
    # have_enqueued_job, not a before/after delta on the :test adapter's
    # process-global enqueued_jobs array (fragile if another example in the
    # same process enqueues something first).
    expect {
      result = described_class.call(payload)
    }.not_to have_enqueued_job(ProcessInboundMessageJob)

    expect(result.schema_behind?).to be(true)
    expect(CityConnection.with(city_a) { InboundMessage.count }).to eq(0)
  end

  it "num payload com duas mudanças, a cidade atrasada não recebe nada e a saudável segue normal" do
    city_b # força criação
    CityChannel.create!(city: city_b, phone_number_id: "PNID456", waba_id: "WABA2",
                        display_phone_number: "+5511888888888", access_token: "tok2", active: true)
    city_b.update!(schema_version: (CitySchema.expected_version - 1).to_s)

    # M1 (hardening review): the behind change comes FIRST and the healthy
    # one SECOND on purpose — a `next` → `break`/`return` regression in
    # Whatsapp::Ingest.call's loop would stop processing right after the
    # first (behind) change and silently drop the healthy one that follows.
    # With the healthy change first (the old order), that same regression
    # would go unnoticed: the healthy write already happened before the loop
    # ever reached the behind change.
    multi_payload = {
      "entry" => [{
        "changes" => [
          {
            "value" => {
              "metadata" => { "phone_number_id" => "PNID456" },
              "messages" => [{ "id" => "wamid.behind", "from" => "+551199", "type" => "text", "text" => { "body" => "oi" } }]
            }
          },
          {
            "value" => {
              "metadata" => { "phone_number_id" => "PNID123" },
              "messages" => [{ "id" => "wamid.healthy", "from" => "+551188", "type" => "text", "text" => { "body" => "oi" } }]
            }
          }
        ]
      }]
    }

    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    begin
      result = on_platform_queue { described_class.call(multi_payload) }

      expect(result.schema_behind?).to be(true)
      expect(CityConnection.with(city_a) { InboundMessage.count }).to eq(1)
      expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
      expect(CityConnection.with(city_a) { SolidQueue::Job.where(class_name: "ProcessInboundMessageJob").count }).to eq(1)
      expect(CityConnection.with(city_b) { SolidQueue::Job.where(class_name: "ProcessInboundMessageJob").count }).to eq(0)
    ensure
      ActiveJob::Base.queue_adapter = adapter_was
    end
  end

  # T2-c: coverage gap. Every example in this file runs inside the harness's
  # default city context (CityConnection.with(TEST_CITY_A), spec/support/
  # city_test_databases.rb), which masks whether Ingest resolves and enters
  # the channel's own city itself. The real webhook path is NOT inside any
  # city — the controller has no city yet, that is the whole point of
  # phone_number_id routing — so this proves the enqueue lands in city_a's own
  # queue (not the platform queue, and not raising PlatformQueue::Misplaced)
  # even when called from outside any city.
  it "routes the deferred enqueue into the channel's own city queue even when called from outside any city" do
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    begin
      expect {
        on_platform_queue { described_class.call(payload) }
      }.not_to raise_error

      expect(CityConnection.with(city_a) { SolidQueue::Job.where(class_name: "ProcessInboundMessageJob").count })
        .to eq(1)
      expect(on_platform_queue { SolidQueue::Job.where(class_name: "ProcessInboundMessageJob").count }).to eq(0)
    ensure
      ActiveJob::Base.queue_adapter = adapter_was
    end
  end
end
