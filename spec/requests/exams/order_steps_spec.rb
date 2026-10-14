require "rails_helper"
require "json_schemer"

# Contrato §3: agendar (prestador habilitado), coletar, cancelar com motivo;
# 409 com o status atual fora da ordem.
RSpec.describe "Exames — etapas pela unidade", type: :request do
  before { exam_city! }

  let(:unit) { create_unit("UBS Etapas") }
  let(:doctor) { doctor!(unit) }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }
  let(:item) { exam_catalog_item! }
  let(:provider) { exam_provider!.tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:schema) { JSONSchemer.schema(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")) }
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
    expect(schema.valid?(json_body)).to be(true)
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
    expect(schema.valid?(json_body)).to be(true)
  end

  it "resposta na visão clínica deixa trilha; na administrativa, não" do
    sign_in_as(doctor)
    expect { json_post "/exams/orders/#{order.id}/cancel", reason: "Pedido em duplicidade" }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "author", "exam_order_id" => order.id, "user_id" => doctor.id)
    other = exam_order!(patient: exam_patient!(61).first, unit: unit, requester: doctor)
    sign_in_as(reception)
    expect { json_post "/exams/orders/#{other.id}/cancel", reason: "Pedido em duplicidade" }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    expect(json_body["status"]).to eq("cancelled")
  end

  it "prestador simulado só com o laboratório simulado utilizável" do
    order
    simulated = exam_provider!(name: "Laboratório Simulado", simulated: true)
    sign_in_as(reception)
    body = { provider_id: simulated.id, scheduled_at: 2.days.from_now.iso8601, scheduled_place: "Rua B" }
    json_post "/exams/orders/#{order.id}/schedule", body
    expect([ response.status, json_body["error"] ]).to eq([ 422, "provider_not_enabled_for_exam" ])
    Platform::Features.set!(city: Current.city, key: "exam_fhir_inbound", enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: Current.city, key: "fake_lab", enabled: true, maintainer: ledi_maintainer!)
    json_post "/exams/orders/#{order.id}/schedule", body
    expect(json_body["status"]).to eq("scheduled")
  end
end
