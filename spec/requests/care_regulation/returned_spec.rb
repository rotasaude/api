require "rails_helper"

# Módulo 26a, Task 9 (ADR 0044; contrato §5, §13 G6, G10, G12, G14; plano do
# api, Desvios 5, 10 e 13): a unidade solicitante vê os devolvidos (com
# `events`: o motivo da devolução está no evento `returned`) e complementa,
# voltando o pedido a `pending` com a data do pedido original.
RSpec.describe "Regulação — devolvidos e complemento", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let(:regulator) { care_regulator! }
  let(:unit) { create_unit("UBS Solicitante #{SecureRandom.hex(2)}") }
  let(:physician) { doctor!(unit) }
  let(:nurse) { nurse!(unit) }
  let(:return_reason) { "Motivo-da-devolucao-sigiloso" }
  let(:justification) { "Justificativa-nova-sigilosa com os exames anexados" }

  def aged!(days, color = "yellow", **over)
    travel_to(now.change(hour: 12) - days.days)
    regulation_request!(suggested_color: color, unit: unit, **over)
  ensure
    travel_to now
  end

  # Devolvido uma hora antes de agora: o andamento é ordenado por created_at,
  # e o complemento (agora) não empata com a devolução no relógio fixo.
  def returned!(request = aged!(3))
    travel_to(now - 1.hour)
    result = CareRegulation::Decide.call(request: request, decision: "return", reason: return_reason, version: request.version, by: regulator)
    raise "devolução recusada: #{result.reason}" if result.failure?

    request.reload
  ensure
    travel_to now
  end

  def nurse_item!(code = "225120")
    expect(CareRegulation::NurseItems.add(target_type: "specialty", target_code: code, by: regulation_admin!)).to be_ok
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
  def complement(request, **body) = json_post("/regulation/requests/#{request.id}/complement", { version: request.version }.merge(body))

  describe "GET /regulation/returned?unit_id=" do
    it "a enfermeira da unidade vê o devolvido com events (o motivo em texto aberto), trilha de lista; o log não tem o motivo" do
      request = returned!
      aged!(2) # pending da mesma unidade: não aparece
      returned!(regulation_request!(suggested_color: "yellow")) # devolvido de outra unidade: não aparece
      sign_in_as(nurse)
      log = capture_log { get "/regulation/returned", params: { unit_id: unit.id } }
      expect(response).to have_http_status(:ok)
      expect(json_body["requests"].map { |r| r["id"] }).to eq([ request.id ])
      expect(json_body["requests"][0]["events"].last).to include("status" => "returned", "reason" => return_reason)
      expect(viewed.last.payload).to eq("access" => "regulation", "regulation_request_ids" => [ request.id ], "user_id" => nurse.id)
      expect(log).not_to include(return_reason)
    end

    it "sem devolvidos: lista vazia e nenhuma trilha" do
      sign_in_as(physician)
      get "/regulation/returned", params: { unit_id: unit.id }
      expect([ response.status, json_body ]).to eq([ 200, { "requests" => [] } ])
      expect(viewed).to be_empty
    end

    it "profissional de outra unidade, regulador ou CBO que não pede → 403 missing_role" do
      returned!
      [ doctor!(create_unit("UBS Outra Devolvidos")), regulator, screener!(unit, cbo: "322205") ].each do |user|
        sign_in_as(user)
        get "/regulation/returned", params: { unit_id: unit.id }
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      expect(viewed).to be_empty
    end

    it "unit_id ausente, não uuid ou chave desconhecida → 422 invalid_request" do
      sign_in_as(nurse)
      [ {}, { unit_id: "abc" }, { unit_id: unit.id, status: "returned" } ].each do |params|
        get "/regulation/returned", params: params
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body["error"]).to eq("invalid_request")
      end
    end
  end

  describe "POST /regulation/requests/:id/complement" do
    it "a enfermeira complementa o pedido da médica só com a justificativa: 200 pending, requested_at igual, cid10 mantido, evento pending com a justificativa" do
      nurse_item!
      request = returned!
      requested_at = request.requested_at
      due_on = request.due_on
      requester = request.requester_user_id
      sign_in_as(nurse)
      log = capture_log { complement(request, justification: justification) }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "pending", "version" => 4, "cid10" => "I10", "justification" => justification,
                                   "requested_at" => requested_at.iso8601, "due_on" => due_on.iso8601)
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending returned pending])
      expect(json_body["events"].last).to include("reason" => justification)
      expect(request.reload).to have_attributes(status: "pending", requested_at: requested_at, requester_user_id: requester)
      expect(viewed.last.payload).to include("patient_id" => request.patient_id, "user_id" => nurse.id, "access" => "regulation")
      expect(DomainEvent.where(name: "regulation_request.complemented").sole.payload)
        .to eq("regulation_request_id" => request.id, "user_id" => nurse.id)
      expect(log).not_to include("sigilosa")
      expect(DomainEvent.where("payload::text LIKE ?", "%sigilos%")).to be_empty
    end

    it "a enfermeira manda ciap2 K86 → 200 com ciap2; cid10 novo (E119) → 422 cid10_not_allowed_for_cbo path cid10" do
      nurse_item!
      request = returned!
      sign_in_as(nurse)
      complement(request, justification: justification, cid10: "E119")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "cid10_not_allowed_for_cbo", "path" => "cid10" } ])
      complement(request, justification: justification, ciap2: "K86")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("ciap2" => "K86", "cid10" => "I10")
    end

    it "a médica complementa pedido de enfermeira só com ciap2: sem cid10 → 422 diagnosis_required path cid10; com I10 → 200" do
      nurse_item!
      request = returned!(aged!(3, doctor: nurse, cid10: nil, ciap2: "K86"))
      sign_in_as(physician)
      complement(request, justification: justification)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "diagnosis_required", "path" => "cid10" } ])
      complement(request, justification: justification, cid10: "I10")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("cid10" => "I10", "ciap2" => "K86", "status" => "pending")
    end

    it "cid10 null limpa: a enfermeira sem ciap2 → 422 diagnosis_required" do
      nurse_item!
      request = returned!
      sign_in_as(nurse)
      complement(request, justification: justification, cid10: nil)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("diagnosis_required")
    end

    it "G14: cor sugerida nova muda o prazo contando da data original; a mesma cor não mexe" do
      request = returned!
      requested_on = request.requested_at.in_time_zone.to_date
      sign_in_as(physician)
      complement(request, justification: justification, suggested_color: "yellow")
      expect(json_body["due_on"]).to eq((requested_on + 30).iso8601)
      request.reload
      returned!(request)
      complement(request.reload, justification: justification, suggested_color: "red")
      expect(json_body).to include("suggested_color" => "red", "due_on" => (requested_on + 7).iso8601)
    end

    it "enfermeira da unidade com alvo fora da lista → 403 cbo_not_allowed; profissional de outra unidade → 403 missing_role" do
      request = returned!
      sign_in_as(nurse)
      complement(request, justification: justification)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
      sign_in_as(doctor!(create_unit("UBS Outra Complemento")))
      complement(request, justification: justification)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(request.reload).to have_attributes(status: "returned", version: 3)
    end

    it "complementar pending → 409 invalid_transition; versão velha → 409 stale_version" do
      request = aged!(3)
      sign_in_as(physician)
      complement(request, justification: justification)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      returned = returned!(request)
      complement(returned, justification: justification, version: 2)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "stale_version" } ])
    end

    it "corpo inválido → 422 invalid_request com path" do
      request = returned!
      sign_in_as(physician)
      complement(request, justification: "curta")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "justification" } ])
      complement(request, justification: justification, suggested_color: "purple")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "suggested_color" } ])
      complement(request, justification: justification, target_code: "225250")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "target_code" } ])
      complement(request, justification: justification, version: "3")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "version" } ])
      expect(request.reload.status).to eq("returned")
    end
  end
end
