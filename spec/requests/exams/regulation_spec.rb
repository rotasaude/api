require "rails_helper"
require "json_schemer"

# Contrato §4 (F-21.4): exam_regulator ou municipal_admin; urgente primeiro,
# depois o mais antigo; autorizar exige prestador habilitado; negar exige
# motivo e fecha o exame; o motivo nunca vai ao cidadão (Task 17).
RSpec.describe "Exames — regulação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:unit) { create_unit("UBS Regulação") }
  let(:doctor) { doctor!(unit) }
  let(:item) { exam_catalog_item!(requires_authorization: true) }
  let(:provider) { exam_provider!.tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:regulator) { staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator") }
  let(:schema) { JSONSchemer.schema(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")) }

  def order!(priority:, at:)
    travel_to(at) { exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor, priority: priority) }
  end

  it "ordena urgente → mais antigo; autoriza com prestador; nega com motivo" do
    item
    old_routine = order!(priority: "routine", at: 3.days.ago)
    new_urgent = order!(priority: "urgent", at: 1.hour.ago)
    old_urgent = order!(priority: "urgent", at: 2.days.ago)
    sign_in_as(regulator)
    get "/exams/regulation/queue", params: { limit: 2 }
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ old_urgent.id, new_urgent.id ])
    expect(json_body["orders"].first).not_to have_key("events")
    expect(json_body["orders"].first["cid10_justification"]).to be_nil
    expect(schema.valid?(json_body["orders"].first)).to be(true)
    get "/exams/regulation/queue", params: { limit: 2, before: json_body["next_before"] }
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ old_routine.id ])
    expect(json_body["next_before"]).to be_nil

    json_post "/exams/orders/#{old_urgent.id}/authorize", provider_id: exam_provider!(name: "Sem item", items: []).id
    expect(json_body["error"]).to eq("provider_not_enabled_for_exam")
    json_post "/exams/orders/#{old_urgent.id}/authorize", provider_id: provider.id
    expect(json_body).to include("status" => "awaiting_schedule", "provider" => { "id" => provider.id, "name" => provider.name })
    expect(schema.valid?(json_body)).to be(true)
    json_post "/exams/orders/#{new_urgent.id}/deny", reason: ""
    expect(json_body["error"]).to eq("reason_required")
    json_post "/exams/orders/#{new_urgent.id}/deny", reason: "Sem indicação clínica descrita"
    expect(json_body["status"]).to eq("denied")
    expect(json_body["events"].last).to include("kind" => "denied", "reason" => "Sem indicação clínica descrita") # A32
    expect(schema.valid?(json_body)).to be(true)
    json_post "/exams/orders/#{new_urgent.id}/authorize", provider_id: provider.id
    expect([ response.status, json_body["status"] ]).to eq([ 409, "denied" ])
  end

  it "só regulador ou admin municipal" do
    sign_in_as(doctor)
    get "/exams/regulation/queue"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    json_post "/exams/orders/#{SecureRandom.uuid}/deny", reason: "x"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(municipal_admin!)
    get "/exams/regulation/queue"
    expect(response).to have_http_status(:ok)
  end

  it "não deixa trilha clínica; cursor inválido 422; pedido inexistente 404" do
    item
    order = order!(priority: "routine", at: 1.day.ago)
    sign_in_as(regulator)
    expect { json_post "/exams/orders/#{order.id}/authorize", provider_id: provider.id }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    get "/exams/regulation/queue", params: { before: "lixo" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_cursor" ])
    json_post "/exams/orders/#{SecureRandom.uuid}/deny", reason: "Sem indicação"
    expect(response).to have_http_status(:not_found)
  end

  it "autorizar e negar concorrentes: um vence, o outro recebe 409 invalid_transition" do
    item
    order = order!(priority: "routine", at: 1.day.ago)
    sign_in_as(regulator)
    json_post "/exams/orders/#{order.id}/deny", reason: "Sem indicação clínica"
    expect(response).to have_http_status(:ok)
    # o segundo, que leu o pedido antes, é barrado pelo lock + estado atual
    json_post "/exams/orders/#{order.id}/authorize", provider_id: provider.id
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "status" => "denied" } ])
    expect(order.reload.events.where(kind: %w[authorized denied]).count).to eq(1)
  end
end
