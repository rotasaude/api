require "rails_helper"

# Cobertura do caminho HTTP do webhook (ADR-0007): handshake de verificação,
# HMAC, e o guard de schema atrasado (Whatsapp::Ingest). O guard em si já é
# testado a fundo em spec/services/whatsapp/ingest_spec.rb — aqui só provamos
# que o controller lê o resultado e responde certo.
RSpec.describe "Webhooks::Whatsapp", type: :request do
  include ActiveJob::TestHelper

  let(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let!(:channel) do
    CityChannel.create!(city: city, phone_number_id: "PNIDREQ", waba_id: "WABAREQ",
                        display_phone_number: "+5511999999999", access_token: "tok", active: true)
  end

  let(:payload) do
    {
      "entry" => [{
        "changes" => [{
          "value" => {
            "metadata" => { "phone_number_id" => "PNIDREQ" },
            "messages" => [{ "id" => "wamid.req1", "from" => "+551188", "type" => "text", "text" => { "body" => "oi" } }]
          }
        }]
      }]
    }
  end

  def signature_for(raw_body)
    "sha256=" + OpenSSL::HMAC.hexdigest("sha256", ENV.fetch("WHATSAPP_APP_SECRET"), raw_body)
  end

  def post_whatsapp(body_payload, signature: nil)
    raw_body = body_payload.to_json
    post "/webhooks/whatsapp", params: raw_body, headers: {
      "CONTENT_TYPE" => "application/json",
      "X-Hub-Signature-256" => signature || signature_for(raw_body)
    }
  end

  describe "GET /webhooks/whatsapp (handshake de verificação)" do
    it "devolve o challenge quando o verify_token confere" do
      get "/webhooks/whatsapp", params: {
        "hub.mode" => "subscribe",
        "hub.verify_token" => ENV.fetch("WHATSAPP_VERIFY_TOKEN"),
        "hub.challenge" => "challenge-123"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("challenge-123")
    end

    it "responde 403 quando o verify_token não confere" do
      get "/webhooks/whatsapp", params: {
        "hub.mode" => "subscribe",
        "hub.verify_token" => "token-errado",
        "hub.challenge" => "challenge-123"
      }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /webhooks/whatsapp" do
    it "responde 401 quando a assinatura HMAC não confere" do
      post_whatsapp(payload, signature: "sha256=" + ("0" * 64))

      expect(response).to have_http_status(:unauthorized)
      expect(CityConnection.with(city) { InboundMessage.count }).to eq(0)
    end

    it "grava a mensagem e responde 200 para uma cidade saudável" do
      expect {
        post_whatsapp(payload)
      }.to change { CityConnection.with(city) { InboundMessage.count } }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "responde 503 com o corpo de schema atrasado e não grava nada para essa cidade" do
      city.update!(schema_version: (CitySchema.expected_version - 1).to_s)

      expect {
        expect {
          post_whatsapp(payload)
        }.not_to change { CityConnection.with(city) { InboundMessage.count } }
      }.not_to have_enqueued_job(ProcessInboundMessageJob) # M3 (hardening review)

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body)).to eq("error" => "city_schema_behind")
    end
  end
end
