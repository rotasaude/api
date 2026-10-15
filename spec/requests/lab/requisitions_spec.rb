require "rails_helper"

# Contrato §4 (F-21.16): a requisição junta exames do 21a do paciente; papel
# vira lab_reception; uma amostra por material/recipiente; no 21a o exame vai
# a `scheduled` no laboratório; previsão = maior prazo de entrega.
RSpec.describe "Laboratório — requisição", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider!(name: "Laboratório Municipal Central") }
  let!(:glucose) { lab_exam!(provider: provider, delivery_days: 2) }
  let!(:lipids) do
    lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Perfil lipídico", analytes: LabHelpers::LIPIDS,
              material: "Soro", container: "Tubo amarelo (gel)", instrument_test_code: "LIP", delivery_days: 4)
  end
  let(:unit) { create_unit("UBS Jardim").tap { |u| u.update!(collects_samples: true) } }
  let(:doctor) { doctor!(unit) }
  let(:patient) { exam_patient!(exam_seq!).first }
  let(:staff) { lab_staff! }
  let!(:order_glucose) { exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202010473") }
  let!(:order_lipids) { exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202010295") }

  def body(**over)
    { patient_id: patient.id, provider_id: provider.id, origin_unit_id: unit.id, collection_place: "lab", biological_sex: "female",
      mother_name: "Joana da Silva", urgent: false, clinical_info: "Em uso de metformina", exam_order_ids: [ order_glucose.id, order_lipids.id ] }.merge(over)
  end

  it "abre no posto do laboratório: duas amostras, itens, 21a agendado no laboratório, previsão pelo maior prazo" do
    sign_in_as(staff)
    get "/lab/candidate_orders", params: { patient_id: patient.id, provider_id: provider.id }
    expect(json_body["orders"].map { |o| o["id"] }).to contain_exactly(order_glucose.id, order_lipids.id)
    expect(json_body["orders"].first.keys).to contain_exactly(*%w[id short_code sigtap_code label priority status requester_name])
    json_post "/lab/requisitions", body
    expect(response).to have_http_status(:created)
    req = json_body
    expect(req).to include("number" => match(/\A\d{8}\z/), "collection_place" => "lab", "status" => "open",
                           "expected_delivery_on" => (Time.zone.today + 4).iso8601)
    expect(req["patient"]).to include("id" => patient.id, "biological_sex" => "female")
    expect(req["samples"].map { |s| [ s["material"], s["barcode"] ] })
      .to contain_exactly([ "Plasma", "#{req['number']}01" ], [ "Soro", "#{req['number']}02" ])
    expect(req["items"].map { |i| i["label"] }).to contain_exactly("Glicose", "Perfil lipídico")
    expect(order_glucose.reload).to have_attributes(status: "scheduled", exam_provider_id: provider.id)
    expect(LabRequisition.find(req["id"]).mother_name).to eq("Joana da Silva")
    expect(DomainEvent.where(name: "lab_requisition.opened").sole.payload.keys).to contain_exactly("lab_requisition_id", "collection_place", "urgent")
    get "/lab/candidate_orders", params: { patient_id: patient.id, provider_id: provider.id }
    expect(json_body["orders"]).to eq([])
    json_post "/lab/requisitions", body
    expect(json_body["error"]).to eq("order_not_eligible")
  end

  it "na UBS que coleta, pela enfermagem com vínculo; UBS que não coleta recusa" do
    sign_in_as(doctor)
    json_post "/lab/requisitions", body(collection_place: "ubs")
    expect(response).to have_http_status(:created)
    other = create_unit("UBS Sem Coleta")
    sign_in_as(doctor!(other))
    json_post "/lab/requisitions", body(collection_place: "ubs", origin_unit_id: other.id, exam_order_ids: [ exam_order!(patient: patient, unit: other, requester: doctor, sigtap_code: "0202010473").id ])
    expect(json_body["error"]).to eq("unit_does_not_collect")
    sign_in_as(doctor)
    json_post "/lab/requisitions", body(collection_place: "lab")
    expect(json_body["error"]).to eq("missing_role")
  end

  it "pedido em papel vira exame lab_reception; erros do corpo" do
    sign_in_as(staff)
    json_post "/lab/requisitions", body(exam_order_ids: [], paper_orders: [ { sigtap_code: "0202010473", requester: { name: "Dr. Externo", cns: Professionals::Cns.generate("externo") } } ])
    expect(response).to have_http_status(:created)
    order = ExamOrder.find(json_body["items"].sole["exam_order_id"])
    expect(order).to have_attributes(origin: "lab_reception", requester_user_id: nil, unit_id: unit.id, status: "scheduled")
    { { mother_name: " " } => "mother_name_required", { biological_sex: "x" } => "biological_sex_required",
      { exam_order_ids: [], paper_orders: [ { sigtap_code: "0202020380", requester: { user_id: doctor.id } } ] } => "exam_not_in_lab_catalog",
      { exam_order_ids: [], paper_orders: [ { sigtap_code: "0202010473", requester: { name: "X", cns: "123" } } ] } => "invalid_cns",
      { exam_order_ids: [], paper_orders: [] } => "invalid_orders",
      { collection_place: "casa" } => "invalid_collection_place" }.each do |over, error|
      json_post "/lab/requisitions", body(**over)
      expect(json_body["error"]).to eq(error), over.inspect
    end
  end

  it "lista e detalhe: laboratório vê os seus; UBS vê os da unidade; estranho 403; filtros por número e código de barras" do
    req = open_requisition!(provider: provider, exams: [ glucose ], unit: unit, by: staff)
    sign_in_as(staff)
    get "/lab/requisitions", params: { number: req.number }
    expect(json_body["requisitions"].sole).to include("id" => req.id, "status" => "open")
    expect(json_body["requisitions"].sole.keys).not_to include("items", "samples")
    get "/lab/requisitions", params: { barcode: req.samples.first.barcode }
    expect(json_body["requisitions"].size).to eq(1)
    sign_in_as(doctor)
    get "/lab/requisitions/#{req.id}"
    expect(json_body["number"]).to eq(req.number)
    get "/lab/requisitions", params: { origin_unit_id: unit.id }
    expect(json_body["requisitions"].map { |r| r["id"] }).to eq([ req.id ])
    sign_in_as(doctor!(create_unit("UBS Longe")))
    get "/lab/requisitions/#{req.id}"
    expect(response).to have_http_status(:forbidden)
  end
end

