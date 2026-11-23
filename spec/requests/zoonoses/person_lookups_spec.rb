require "rails_helper"

# Módulo 35b, Task 5 (ADR 0054; contrato §2, Q25): POST /zoonoses/person_lookup,
# a busca do tutor (e do adotante) pelo CPF ou pelo CNS, só no corpo, no molde
# do TerritoryRegistry::PersonLookupsController: devolve o paciente e o
# domicílio do cadastro individual ativo (24a) com o endereço curto; trilha
# por pessoa mostrada (e a do domicílio mostrado); 30 por minuto por usuário.
RSpec.describe "Zoonoses — busca de pessoa", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }

  def lookup(body = {}, query: "", **fields) = post("/zoonoses/person_lookup#{query}", params: body.merge(fields).to_json, headers: headers)
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload)

  before { sign_in_as(team) }

  it "CPF no corpo → paciente e o domicílio do cadastro ativo com address_short; sem cadastro → household null" do
    registration = registry_registration!
    patient = registration.patient
    lookup(cpf: patient.cpf)
    expect(response).to have_http_status(:ok)
    address = HomeVisits::Json.addresses([ registration.household_id ]).fetch(registration.household_id)
    expect(json_body).to eq("patient" => { "id" => patient.id, "display_name" => patient.display_name },
                            "household" => { "id" => registration.household_id, "address_short" => address })
    expect(response.body).not_to include(patient.cpf)

    loose = tutor!
    lookup(cpf: loose.cpf)
    expect(json_body).to eq("patient" => { "id" => loose.id, "display_name" => loose.display_name }, "household" => nil)
  end

  it "CNS no corpo → paciente; CPF e CNS juntos → 422 path cns; chave desconhecida → 422 path da chave" do
    patient = registry_no_cpf_patient!
    lookup(cns: patient.cns)
    expect(json_body["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name)
    lookup(cpf: tutor!.cpf, cns: patient.cns)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cns" } ])
    lookup(name: "Fulana")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
    lookup(cpf: "123")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cpf", "path" => "cpf" } ])
  end

  it "CPF na query → 422, nada lido da URL, sem trilha" do
    patient = tutor!
    lookup({}, query: "?cpf=#{patient.cpf}")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(trail).to be_empty
  end

  it "ninguém → 404 person_not_found, sem trilha; stock_keeper → 403 missing_role" do
    lookup(cpf: valid_cpf(9_997))
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
    expect(trail).to be_empty
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    lookup(cpf: tutor!.cpf)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "a 31ª no minuto → 429" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    30.times { lookup(cpf: valid_cpf(9_996)) }
    expect(response).to have_http_status(:not_found)
    lookup(cpf: valid_cpf(9_996))
    expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
  end

  it "trilha por pessoa mostrada (access zoonoses) e a do domicílio mostrado; só ids" do
    registration = registry_registration!
    patient = registration.patient
    lookup(cpf: patient.cpf)
    expect(trail).to eq([
      { "patient_id" => patient.id, "user_id" => team.id, "access" => "zoonoses", "reason_code" => nil,
        "person_ref" => "patient:#{patient.id}" },
      { "access" => "territory_registry", "household_id" => registration.household_id, "user_id" => team.id }
    ])
    expect(trail.to_json).not_to include(patient.cpf, patient.display_name)
  end
end
