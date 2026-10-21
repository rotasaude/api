require "rails_helper"

# B3, B4 e B5 do dashboard: paciente pelo CPF (corpo, com trilha), lista de
# estabelecimentos faturantes e de profissionais do estabelecimento.
RSpec.describe "Faturamento — buscas de apoio", type: :request do
  before { billing_city! }

  let(:unit) { upa! }
  let(:pair) { exam_patient!(exam_seq!) }

  it "paciente pelo CPF: faturista e profissional de unidade não-APS; trilha só com ids; 404 e 422" do
    sign_in_as(billing_clerk!)
    json_post "/billing/patient_lookup", cpf: pair.first.cpf
    expect(json_body).to eq("patient" => { "id" => pair.first.id, "display_name" => "Maria Aparecida da Silva",
                                           "cpf_masked" => pair.first.cpf_masked })
    expect(DomainEvent.where(name: "billing_patient.looked_up").last.payload.keys).to match_array(%w[patient_id user_id])
    json_post "/billing/patient_lookup", cpf: "52998224725"
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "patient_not_found")
    json_post "/billing/patient_lookup", cpf: "123"
    expect(json_body).to eq("error" => "invalid_cpf")
    sign_in_as(doctor!(unit))
    json_post "/billing/patient_lookup", cpf: pair.first.cpf
    expect(response).to have_http_status(:ok)
    sign_in_as(doctor!(create_unit("UBS #{SecureRandom.hex(2)}")))
    json_post "/billing/patient_lookup", cpf: pair.first.cpf
    expect(response).to have_http_status(:forbidden)
  end

  it "estabelecimentos faturantes: unidades não-APS ativas e laboratórios municipais; faturista e admin" do
    create_unit("UBS #{SecureRandom.hex(2)}")
    lab = lab_provider!
    unit
    sign_in_as(lab_admin!)
    get "/billing/establishments"
    expect(json_body["establishments"]).to include({ "type" => "health_unit", "id" => unit.id, "cnes" => unit.cnes, "name" => unit.name },
                                                   { "type" => "lab_provider", "id" => lab.id, "cnes" => lab.cnes, "name" => lab.name })
    expect(json_body["establishments"].map { |e| e["id"] }).not_to include(*HealthUnit.where(kind: "ubs").pluck(:id))
    sign_in_as(doctor!(unit))
    get "/billing/establishments"
    expect(response).to have_http_status(:forbidden)
  end

  it "profissionais do estabelecimento: vínculos ativos na unidade; liberadores no laboratório; só faturista" do
    doctor = doctor!(unit)
    lab = lab_provider!
    releaser = lab_releaser!(lab)
    sign_in_as(billing_clerk!)
    get "/billing/professionals", params: { establishment_type: "health_unit", establishment_id: unit.id }
    expect(json_body["professionals"]).to eq([ { "user_id" => doctor.id, "name" => doctor.professional.professional_name, "cbo_codes" => %w[225125] } ])
    get "/billing/professionals", params: { establishment_type: "lab_provider", establishment_id: lab.id }
    expect(json_body["professionals"].map { |p| p["user_id"] }).to eq([ releaser.id ])
    get "/billing/professionals", params: { establishment_type: "health_unit", establishment_id: SecureRandom.uuid }
    expect(json_body).to eq("error" => "invalid_establishment")
    sign_in_as(lab_admin!)
    get "/billing/professionals", params: { establishment_type: "health_unit", establishment_id: unit.id }
    expect(response).to have_http_status(:forbidden)
  end
end
