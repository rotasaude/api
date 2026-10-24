require "rails_helper"

# Módulo 24a (ADR 0042; contrato §4, §14 L6, L7, L11; F-24.4): domicílios e
# famílias pela equipe; cada gravação é versão imutável nova e ficha de
# cadastro domiciliar; leitura com trilha clinical_record.viewed
# (access territory_registry), uma por consulta, só ids.
RSpec.describe "Território — domicílios e famílias", type: :request do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:neighborhood) { care_neighborhood!(unit) }
  let(:body) do
    { micro_area_id: area.id, property_type: "1", refused: false, contact_phone: "41999990000",
      address: { zip: "81000000", street_type: "081", street: "Rua das Acácias", number: "120", no_number: false, complement: "casa 2",
                 neighborhood_id: neighborhood.id, reference: "perto da escola" },
      living_conditions: { localizacao: 83, situacao_moradia_posse_terra: 75 } }
  end

  it "ACS da microárea cria e atualiza com versão; cada gravação é versão nova e ficha domiciliar" do
    sign_in_as(acs)
    json_post "/territory/households", body
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 1, "status" => "active", "property_type" => "1", "families" => [], "refused" => false,
                                 "micro_area" => { "id" => area.id, "code" => "01" })
    expect(json_body["address"]).to include("street" => "Rua das Acácias", "neighborhood_id" => neighborhood.id)
    id = json_body["id"]
    expect(LediOutboxEntry.where(ficha_type: "cadastro_domiciliar").count).to eq(1)
    json_patch "/territory/households/#{id}", body.merge(version: 1, contact_phone: "41988880000")
    expect(response).to have_http_status(:ok)
    expect(json_body["version"]).to eq(2)
    expect(HouseholdVersion.where(household_id: id).count).to eq(2)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_domiciliar").count).to eq(2)
    json_patch "/territory/households/#{id}", body.merge(version: 1)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "stale_version")
    json_patch "/territory/households/#{id}", body
    expect(json_body).to eq("error" => "invalid_household", "path" => "version")
    expect(DomainEvent.where(name: "household.saved").last.payload.keys).to match_array(%w[household_id household_version_id user_id])
  end

  it "endereço maior que o layout do BPA é recusado com path, nada gravado" do
    sign_in_as(acs)
    json_post "/territory/households", body.deep_merge(address: { street: "R" * 31 })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_household", "path" => "address.street")
    json_post "/territory/households", body.deep_merge(address: { number: "1234A6" })
    expect(json_body).to eq("error" => "invalid_household", "path" => "address.number")
    json_post "/territory/households", body.deep_merge(address: { complement: "C" * 11 })
    expect(json_body).to eq("error" => "invalid_household", "path" => "address.complement")
    expect(Household.count).to eq(0)
    expect(HouseholdVersion.count).to eq(0)
  end

  it "endereço obrigatório sem recusa; microárea inativa nunca é destino; regras da ficha com path" do
    sign_in_as(acs)
    json_post "/territory/households", body.except(:address)
    expect(json_body).to eq("error" => "invalid_household", "path" => "address")
    json_post "/territory/households", body.merge(living_conditions: { localizacao: 83 })
    expect(json_body).to eq("error" => "invalid_household", "path" => "living_conditions.situacao_moradia_posse_terra")
    json_post "/territory/households", body.except(:address, :living_conditions).merge(refused: true)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("refused" => true, "address" => {})
    area.update!(active: false)
    json_post "/territory/households", body
    expect(json_body).to eq("error" => "invalid_household", "path" => "micro_area_id")
    expect(Household.count).to eq(1)
  end

  it "família: troca de responsável gera versão do domicílio e ficha; responsável repetido recusado" do
    sign_in_as(acs)
    json_post "/territory/households", body
    id = json_body["id"]
    patient = care_patient!(age: 40, sex: "female")
    json_post "/territory/households/#{id}/families", responsible: { patient_id: patient.id }, income_band: "3", members_count: 3,
                                                      living_since: "2020-03", version: 1
    expect(response).to have_http_status(:created)
    expect(Household.find(id).version).to eq(2)
    expect(json_body["families"]).to contain_exactly(include("responsible" => { "patient_id" => patient.id, "display_name" => patient.display_name },
                                                             "income_band" => "3", "members_count" => 3, "living_since" => "2020-03",
                                                             "moved_out" => false))
    expect(LediOutboxEntry.where(ficha_type: "cadastro_domiciliar").count).to eq(2)
    expect(Household.find(id).latest_version.families_snapshot.first).to include("responsible_patient_id" => patient.id, "moved_out" => false)
    json_post "/territory/households/#{id}/families", responsible: { patient_id: patient.id }, members_count: 1, version: 2
    expect(json_body).to eq("error" => "invalid_family", "path" => "responsible.patient_id")
    json_post "/territory/households/#{id}/families", responsible: { patient_id: patient.id }, members_count: 0, version: 2
    expect(json_body).to eq("error" => "invalid_family", "path" => "members_count")
    expect(Family.count).to eq(1)
  end

  it "família muda (moved_out) e só então o domicílio fica inativo; famílias com versão esperada" do
    sign_in_as(acs)
    json_post "/territory/households", body
    id = json_body["id"]
    patient = care_patient!(age: 40, sex: "female")
    json_post "/territory/households/#{id}/families", responsible: { patient_id: patient.id }, members_count: 2, version: 1
    family_id = json_body["families"].first["id"]
    json_patch "/territory/households/#{id}", body.merge(version: 2, status: "inactive")
    expect(json_body).to eq("error" => "invalid_household", "path" => "status")
    json_patch "/territory/families/#{family_id}", members_count: 2, moved_out: true, version: 1
    expect(json_body).to eq("error" => "stale_version")
    json_patch "/territory/families/#{family_id}", members_count: 2, moved_out: true, version: 2
    expect(response).to have_http_status(:ok)
    expect(json_body["version"]).to eq(3)
    json_patch "/territory/households/#{id}", body.merge(version: 3, status: "inactive")
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "inactive", "version" => 4)
    json_patch "/territory/families/#{family_id}", members_count: 2, moved_out: false, version: 4
    expect(json_body).to eq("error" => "invalid_family", "path" => "moved_out")
  end

  it "escopo: ACS de outra microárea → 403; domicílio de outra equipe por id → 404; lista com trilha por consulta, sem moradia" do
    other_acs = registry_acs!(unit, team: team)
    registry_micro_area!(code: "02", team: team, acs: other_acs)
    sign_in_as(other_acs)
    json_post "/territory/households", body
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    get "/territory/households", params: { micro_area_id: area.id }
    expect(json_body).to eq("error" => "out_of_scope")
    household = registry_household!(micro_area: registry_micro_area!(code: "05", team: registry_team!(care_unit!)))
    get "/territory/households/#{household.id}"
    expect(response).to have_http_status(:not_found)
    json_patch "/territory/households/#{household.id}", body.merge(version: 1)
    expect(response).to have_http_status(:not_found)
    sign_in_as(acs)
    json_post "/territory/households", body
    first_id = json_body["id"]
    json_post "/territory/households", body
    second_id = json_body["id"]
    events = DomainEvent.where(name: "clinical_record.viewed")
    expect { get "/territory/households", params: { micro_area_id: area.id } }.to change(events, :count).by(1)
    expect(json_body["households"].map { |row| row["id"] }).to match_array([ first_id, second_id ])
    expect(json_body["households"].first).not_to have_key("living_conditions")
    expect(json_body).to have_key("next_before")
    payload = events.order(:created_at).last.payload
    expect(payload.keys).to match_array(%w[access micro_area_id household_ids user_id])
    expect(payload).to include("access" => "territory_registry", "micro_area_id" => area.id, "user_id" => acs.id)
    expect(payload["household_ids"]).to match_array([ first_id, second_id ])
    expect(DomainEvent.where(name: %w[territory_households.listed territory_household.viewed])).to be_empty
  end

  it "detalhe com moradia e trilha; paginação por next_before; limite inválido → 422 invalid_limit" do
    sign_in_as(acs)
    ids = Array.new(3) { json_post("/territory/households", body) && json_body["id"] }
    get "/territory/households/#{ids.first}"
    expect(json_body).to include("id" => ids.first, "living_conditions" => { "localizacao" => 83, "situacao_moradia_posse_terra" => 75 },
                                 "registered_by" => { "name" => acs.professional.professional_name })
    payload = DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last.payload
    expect(payload).to eq("access" => "territory_registry", "household_id" => ids.first, "user_id" => acs.id)
    get "/territory/households", params: { micro_area_id: area.id, limit: 2 }
    page = json_body["households"].map { |row| row["id"] }
    expect(page.size).to eq(2)
    get "/territory/households", params: { micro_area_id: area.id, limit: 2, before: json_body["next_before"] }
    expect(json_body).to include("next_before" => nil)
    expect(page + json_body["households"].map { |row| row["id"] }).to match_array(ids)
    get "/territory/households", params: { micro_area_id: area.id, limit: 101 }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_limit")
  end

  it "enfermeiro da equipe grava em qualquer microárea dela; profissional com CBO fora da tabela → 403 cbo_not_allowed" do
    nurse = registry_nurse!(unit, team: team)
    sign_in_as(nurse)
    json_post "/territory/households", body
    expect(response).to have_http_status(:created)
    expect(HouseholdVersion.last).to have_attributes(saved_cbo: "223505", team_id: team.id, saved_by_user_id: nurse.id)
    endemic = registry_field_professional!(unit, team: team, cbo: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO, council: false)
    sign_in_as(endemic)
    json_post "/territory/households", body
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
  end

  # Contrato §14 L20 (rulings, adendo T9): sem IBGE ou sem UF no perfil da
  # cidade a gravação nunca dá 500 nem desfaz — a ficha fica "não gerada".
  it "sem IBGE: 201 e nenhuma ficha (não gerada city_profile_incomplete); sem UF, o mesmo" do
    sign_in_as(acs)
    CityProfile.current.update!(ibge_code: nil)
    json_post "/territory/households", body
    expect(response).to have_http_status(:created)
    version = HouseholdVersion.find_by!(household_id: json_body["id"])
    expect(LediOutboxEntry.where(ficha_type: "cadastro_domiciliar")).to be_empty
    expect(LediGenerationFailure.find_by!(source_id: version.id).reason_codes).to eq(%w[city_profile_incomplete])
    CityProfile.current.update!(ibge_code: "4115200", uf: nil)
    json_patch "/territory/households/#{json_body['id']}", body.merge(version: 1)
    expect(response).to have_http_status(:ok)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_domiciliar")).to be_empty
    expect(LediGenerationFailure.where(source_type: "HouseholdVersion").pluck(:reason_codes)).to all(eq(%w[city_profile_incomplete]))
  end
end
