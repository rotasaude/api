require "rails_helper"

# Painel "Exames atrasados" (spec §5): a unidade filtra por etapa,
# prestador e exame; cada pedido diz a etapa, o prazo e os dias de atraso.
RSpec.describe "Exames — atrasos", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:unit) { create_unit("UBS Atrasos") }
  let(:doctor) { doctor!(unit) }

  it "filtra os atrasados e mostra etapa, prazo e dias" do
    late = travel_to(20.days.ago) { exam_order!(patient: exam_patient!(70).first, unit: unit, requester: doctor) }
    exam_order!(patient: exam_patient!(71).first, unit: unit, requester: doctor)
    sign_in_as(staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    get "/exams/orders", params: { unit_id: unit.id, overdue: "true", stage: "schedule", sigtap_code: "0202010503" }
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ late.id ])
    expect(json_body["orders"].first["overdue"]).to eq("stage" => "schedule", "due_on" => late.stage_due_on.iso8601, "days_late" => 5)
    get "/exams/orders", params: { unit_id: unit.id, overdue: "true", stage: "result" }
    expect(json_body["orders"]).to eq([])
  end

  it "coordenação: admin e regulador veem os atrasos da cidade inteira; a recepção não (dashboard D15)" do
    late = travel_to(20.days.ago) { exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor) }
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    get "/exams/orders", params: { overdue: "true" }
    expect(json_body["orders"].map { |o| [ o["id"], o["unit"]["name"] ] }).to eq([ [ late.id, "UBS Atrasos" ] ])
    get "/exams/orders"
    expect(json_body["error"]).to eq("filter_required")
    sign_in_as(staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    get "/exams/orders", params: { overdue: "true" }
    expect(json_body["error"]).to eq("filter_required")
  end
end
