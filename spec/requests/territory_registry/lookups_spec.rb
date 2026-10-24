require "rails_helper"

# Módulo 24a (contrato §14 L2, L3): as equipes do profissional com as
# microáreas ativas e se ele pode gravar ficha nelas; a pessoa pelo CPF (só
# no corpo), com o cadastro ativo.
RSpec.describe "Território — equipes do profissional e pessoa pelo CPF", type: :request do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }

  it "GET /territory/teams: equipes do vínculo, microáreas ativas, can_register pela regra da gravação" do
    mine = registry_micro_area!(code: "01", team: team, acs: acs)
    other = registry_micro_area!(code: "02", team: team)
    registry_micro_area!(code: "03", team: team).update!(active: false)
    registry_team!(care_unit!)
    sign_in_as(acs)
    get "/territory/teams"
    expect(response).to have_http_status(:ok)
    row = json_body["teams"].sole
    expect(row).to include("id" => team.id, "ine" => team.ine, "name" => team.name, "unit" => { "id" => unit.id, "name" => unit.name })
    expect(row["micro_areas"].map { _1.values_at("id", "code", "can_register") }).to eq([ [ mine.id, "01", true ], [ other.id, "02", false ] ])
    sign_in_as(registry_nurse!(unit, team: team))
    get "/territory/teams"
    expect(json_body["teams"].sole["micro_areas"].pluck("can_register")).to eq([ true, true ])
    sign_in_as(care_admin!)
    get "/territory/teams"
    expect(json_body).to eq("teams" => [])
  end

  it "POST /territory/person_lookup: paciente, par validado sem paciente, ninguém; CPF só no corpo; trilha" do
    registration = registry_registration!
    patient = registration.patient
    sign_in_as(acs)
    json_post "/territory/person_lookup", cpf: patient.cpf
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("patient_id" => patient.id, "citizen_id" => nil, "display_name" => patient.display_name,
                            "registration_id" => registration.id)
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("access" => "territory_registry", "patient_id" => patient.id)
    citizen = verified_citizen!(21)
    json_post "/territory/person_lookup", cpf: citizen.cpf
    expect(json_body).to eq("patient_id" => nil, "citizen_id" => citizen.id, "display_name" => citizen.full_name, "registration_id" => nil)
    json_post "/territory/person_lookup", cpf: valid_cpf(999)
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "person_not_found")
    json_post "/territory/person_lookup", cpf: "123"
    expect(json_body).to eq("error" => "invalid_cpf")
    post "/territory/person_lookup?cpf=#{patient.cpf}", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body).to eq("error" => "invalid_request")
    sign_in_as(care_admin!)
    json_post "/territory/person_lookup", cpf: patient.cpf
    expect(response).to have_http_status(:forbidden)
  end
end
