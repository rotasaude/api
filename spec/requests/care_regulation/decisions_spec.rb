require "rails_helper"

# Módulo 26a (ADR 0044; contrato §4, §13 G5): as decisões do regulador.
# Task 8: autorizar (POST /regulation/requests/:id/authorize), só o
# care_regulator, corpo JSON; 200 com o <regulation_request> completo (com
# events), que o dashboard aplica sem reler.
RSpec.describe "Regulação — decisões do regulador", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let(:regulator) { care_regulator! }
  let(:offer) { offer!(provider: external_provider!) }

  let(:contract_keys) do
    %w[id patient type target cid10 ciap2 justification suggested_color color color_reason status requested_at due_on overdue requester
       consultation_id authorization appointment_request_id schedule outcome misses external state_regulated version events]
  end

  def aged!(days, color, **over)
    travel_to(now.change(hour: 12) - days.days)
    regulation_request!(suggested_color: color, **over)
  ensure
    travel_to now
  end

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)

  describe "POST /regulation/requests/:id/authorize" do
    before { sign_in_as(regulator) }

    it "200 com a forma do contrato (com events), a trilha por pessoa e o evento authorized só com ids" do
      request = aged!(3, "yellow")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to match_array(contract_keys)
      expect(json_body).to include("id" => request.id, "status" => "authorized", "version" => 3, "color" => nil, "color_reason" => nil,
                                   "appointment_request_id" => nil)
      expect(json_body["authorization"]).to eq(
        "offer_id" => offer.id, "provider" => { "id" => offer.care_provider_id, "name" => offer.care_provider.name, "kind" => "contracted" },
        "month" => "2026-10", "skip_reason" => nil, "at" => now.iso8601, "by" => json_body.dig("authorization", "by")
      )
      expect(json_body.dig("authorization", "by").keys).to eq([ "name" ])
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending authorized])
      expect(viewed.last.payload).to include("access" => "regulation", "patient_id" => request.patient_id, "user_id" => regulator.id,
                                             "person_ref" => "patient:#{request.patient_id}")
      expect(DomainEvent.where(name: "regulation_request.authorized").sole.payload)
        .to eq("regulation_request_id" => request.id, "user_id" => regulator.id)
    end

    it "rede própria: 200 com appointment_request_id do pedido regulated" do
      unit = create_unit("Centro de Especialidades Decisões")
      own = offer!(provider: own_provider!(unit))
      request = aged!(3, "red")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: own.id, version: request.version
      expect(response).to have_http_status(:ok)
      appointment = AppointmentRequest.find_by!(origin_regulation_request_id: request.id)
      expect(json_body["appointment_request_id"]).to eq(appointment.id)
      expect(json_body.dig("authorization", "provider", "kind")).to eq("own")
    end

    it "409 quota_exhausted, só o erro" do
      request = aged!(3, "yellow")
      empty = offer!(provider: external_provider!, quantity: 0)
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: empty.id, version: request.version
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "quota_exhausted" } ])
    end

    it "422 skip_reason_required sem nenhum dado dos outros pedidos (G5)" do
      aged!(10, "yellow")
      request = aged!(3, "yellow")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("error" => "skip_reason_required")
    end

    it "422 color_reason_required; 409 stale_version; 422 invalid_offer; 409 invalid_transition" do
      request = aged!(3, "yellow")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, color: "red", version: request.version
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "color_reason_required" } ])
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: 1
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "stale_version" } ])
      other = offer!(provider: external_provider!, target_code: "225250")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: other.id, version: request.version
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_offer" } ])
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version
      expect(response).to have_http_status(:ok)
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: 3
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
    end

    it "motivos enviados sem necessidade não voltam na resposta nem ficam gravados" do
      request = aged!(3, "yellow")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version, color: "yellow",
                                                                 color_reason: "Motivo enviado sem mudança de cor",
                                                                 skip_reason: "Motivo de pular sem ninguém à frente"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("color" => "yellow", "color_reason" => nil)
      expect(json_body.dig("authorization", "skip_reason")).to be_nil
    end

    it "409 citizen_not_verified na oferta própria sem par validado" do
      request = aged!(3, "yellow")
      citizen = Citizen.find_by!(patient_id: request.patient_id)
      Citizens::RevokeVerification.call(verification: citizen.active_verification, reason: "Documento de outra pessoa",
                                        by: staff_with("adm-revoga-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
      own = offer!(provider: own_provider!(create_unit("Centro de Especialidades Sem Par")))
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: own.id, version: request.version
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
    end

    it "corpo inválido → 422 invalid_request com path; chave desconhecida também" do
      request = aged!(3, "yellow")
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: "2"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "version" } ])
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: 2, color: "purple"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "color" } ])
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: 2, priority: "x"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "priority" } ])
      expect(request.reload.status).to eq("pending")
    end

    it "dado na query → 422 invalid_request, nada lido da URL" do
      request = aged!(3, "yellow")
      post "/regulation/requests/#{request.id}/authorize?skip_reason=Motivo-na-url-sigiloso",
           params: { offer_id: offer.id, version: request.version }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(request.reload.status).to eq("pending")
    end

    it "id desconhecido, malformado ou de rascunho → 404" do
      draft = regulation_request!(status: "draft")
      [ SecureRandom.uuid, "abc", draft.id ].each do |id|
        json_post "/regulation/requests/#{id}/authorize", offer_id: offer.id, version: 1
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
    end

    it "sem Content-Type JSON → 415 json_required" do
      request = aged!(3, "yellow")
      post "/regulation/requests/#{request.id}/authorize", params: { offer_id: offer.id, version: request.version }
      expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])
    end

    it "o log não contém o skip_reason nem o color_reason" do
      aged!(10, "red") # à frente da cor resultante (vermelho): o skip_reason vale
      request = aged!(3, "yellow")
      log = capture_log do
        json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version, color: "red",
                                                                   color_reason: "Motivo-da-cor-sigiloso", skip_reason: "Motivo-de-pular-sigiloso"
      end
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("color" => "red", "color_reason" => "Motivo-da-cor-sigiloso")
      expect(json_body.dig("authorization", "skip_reason")).to eq("Motivo-de-pular-sigiloso")
      expect(log).to include("authorize")
      expect(log).not_to include("Motivo-da-cor-sigiloso")
      expect(log).not_to include("Motivo-de-pular-sigiloso")
      expect(DomainEvent.where("payload::text LIKE ?", "%sigiloso%")).to be_empty
    end
  end

  describe "outros papéis e interruptor" do
    it "health_professional → 403 missing_role; municipal_admin também" do
      request = aged!(3, "yellow")
      [ doctor!(create_unit("UBS Decisões Outra")), regulation_admin! ].each do |user|
        sign_in_as(user)
        json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      expect(request.reload.status).to eq("pending")
    end

    it "interruptor desligado → 403 feature_disabled" do
      request = aged!(3, "yellow")
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(regulator)
      json_post "/regulation/requests/#{request.id}/authorize", offer_id: offer.id, version: request.version
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end
  end
end
