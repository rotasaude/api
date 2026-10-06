require "rails_helper"

# Invariantes de fechamento do Módulo 01 (borda do WhatsApp) — ver
# docs/modulos/01--whatsapp.md, "Critério de fechamento". Exemplos pequenos e
# diretos, um grupo por invariante; a cobertura a fundo mora nos specs de
# origem (spec/services/whatsapp/ingest_spec.rb, spec/requests/webhooks/
# whatsapp_spec.rb, spec/jobs/purge_inbound_raw_job_spec.rb).
RSpec.describe "WhatsApp edge invariants (module 01 closing criteria)" do
  include ActiveJob::TestHelper

  let(:city) { create(:city, database_url: city_database_url(TEST_CITY_A_DATABASE)) }
  let!(:channel) do
    CityChannel.create!(city: city, phone_number_id: "PNID-INV", waba_id: "WABA-INV",
                        display_phone_number: "+5541999999999", access_token: "tok", active: true)
  end

  def payload(pnid: "PNID-INV", wamid: "wamid.inv")
    metadata = pnid.nil? ? {} : { "phone_number_id" => pnid }
    { "entry" => [{ "changes" => [{ "value" => {
      "metadata" => metadata,
      "messages" => [{ "id" => wamid, "from" => "+551188", "type" => "text", "text" => { "body" => "oi" } }]
    } }] }] }
  end

  def city_inbound_count = CityConnection.with(city) { InboundMessage.count }

  describe "1. dedup by wamid" do
    it "stores one InboundMessage when the same wamid arrives twice" do
      2.times { Whatsapp::Ingest.call(payload) }

      expect(city_inbound_count).to eq(1)
    end
  end

  describe "2. HMAC is mandatory", type: :request do
    def post_webhook(headers)
      post "/webhooks/whatsapp", params: payload.to_json,
                                 headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
    end

    it "rejects a wrong signature with 401 and writes nothing" do
      post_webhook("X-Hub-Signature-256" => "sha256=#{'0' * 64}")

      expect(response).to have_http_status(:unauthorized)
      expect(city_inbound_count).to eq(0)
    end

    it "rejects a missing signature with 401 and writes nothing" do
      post_webhook({})

      expect(response).to have_http_status(:unauthorized)
      expect(city_inbound_count).to eq(0)
    end
  end

  describe "3. fail-closed without a resolved, servable city" do
    def expect_nothing_written
      expect(city_inbound_count).to eq(0)
      expect(InboundMessage.count).to eq(0) # conexão default do harness
    end

    it("unknown phone_number_id") { Whatsapp::Ingest.call(payload(pnid: "PNID-NOPE")); expect_nothing_written }
    it("blank phone_number_id")   { Whatsapp::Ingest.call(payload(pnid: "")); expect_nothing_written }
    it("missing phone_number_id") { Whatsapp::Ingest.call(payload(pnid: nil)); expect_nothing_written }

    it "inactive channel" do
      channel.update!(active: false)
      Whatsapp::Ingest.call(payload)
      expect_nothing_written
    end

    it "non-servable city" do
      city.update!(status: "suspended")
      Whatsapp::Ingest.call(payload)
      expect_nothing_written
    end
  end

  describe "4. raw TTL purge" do
    it "is scheduled in production at RAW_RETENTION_DAYS" do
      task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))
                                             .fetch("production").fetch("purge_inbound_raw")

      expect(task).to include("class" => "PurgeInboundRawJob",
                              "args" => { "older_than_days" => PurgeInboundRawJob::RAW_RETENTION_DAYS })
    end

    it "clears raw older than the window and keeps raw inside it" do
      Current.city = TEST_CITY_A
      make = ->(age) { InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(4)}", from: "5541999990000",
                                              kind: "text", raw: "{}", created_at: age.days.ago) }
      old = make.(PurgeInboundRawJob::RAW_RETENTION_DAYS + 1)
      recent = make.(PurgeInboundRawJob::RAW_RETENTION_DAYS - 1)

      # EachCityJob é prepended: chama o corpo direto, na cidade do harness.
      PurgeInboundRawJob.instance_method(:perform).super_method.bind_call(PurgeInboundRawJob.new)

      expect(old.reload.raw).to be_nil
      expect(recent.reload.raw).to eq("{}")
    end
  end
end
