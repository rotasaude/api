require "rails_helper"

# Contrato §3: agendar (prestador habilitado), coletar, cancelar com motivo;
# 409 com o status atual fora da ordem.
RSpec.describe "Exames — etapas pela unidade", type: :request do
  before { exam_city! }

  let(:unit) { create_unit("UBS Etapas") }
  let(:doctor) { doctor!(unit) }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }
  let(:item) { exam_catalog_item! }
  let(:provider) { exam_provider!.tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:order) { exam_order!(patient: exam_patient!(60).first, unit: unit, requester: doctor) }

  it "agenda, reagenda, coleta; fora da ordem 409; prestador não habilitado 422" do
    sign_in_as(reception)
    json_post "/exams/orders/#{order.id}/collect"
    expect(json_body).to eq("error" => "invalid_transition", "status" => "awaiting_schedule")
    json_post "/exams/orders/#{order.id}/schedule", provider_id: exam_provider!(name: "Outro", items: []).id,
                                                    scheduled_at: 2.days.from_now.iso8601, scheduled_place: "Rua B"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "provider_not_enabled_for_exam" ])
    json_post "/exams/orders/#{order.id}/schedule", provider_id: provider.id, scheduled_at: "amanhã", scheduled_place: "Rua B"
    expect(json_body["error"]).to eq("invalid_schedule")
    json_post "/exams/orders/#{order.id}/schedule", provider_id: provider.id, scheduled_at: 2.days.from_now.iso8601,
                                                    scheduled_place: "Laboratório Central, Rua B, 100"
    expect(json_body).to include("status" => "scheduled", "provider" => { "id" => provider.id, "name" => provider.name })
    json_post "/exams/orders/#{order.id}/collect"
    expect(json_body["status"]).to eq("collected")
  end

  it "cancela com motivo (unidade ou solicitante); sem motivo 422; estranho 403" do
    sign_in_as(doctor!(create_unit("UBS Longe")))
    json_post "/exams/orders/#{order.id}/cancel", reason: "Engano"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(doctor)
    json_post "/exams/orders/#{order.id}/cancel", reason: ""
    expect(json_body["error"]).to eq("reason_required")
    json_post "/exams/orders/#{order.id}/cancel", reason: "Pedido em duplicidade"
    expect(json_body["status"]).to eq("cancelled")
  end
end
