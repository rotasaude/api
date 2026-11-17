require "rails_helper"

# Módulo 35a (ADR 0054; contrato §20 Q13(1), Q14(2)): com vector_control
# utilizável, o agente de endemias (515140) cadastra e edita pelo 24a
# (TerritoryRegistry::SaveHousehold) só imóvel não residencial
# (2 3 4 5 6 12 13), sem família nem morador, nas microáreas atribuídas a ele.
# A versão grava o CBO dele e a ficha 3 sai com ele. Residencial, troca para
# residencial, família e cadastro individual → 403 cbo_not_allowed; microárea
# não atribuída → 403 out_of_scope. O ACS não muda.
RSpec.describe "Território — imóvel não residencial do agente de endemias", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:other_area) { registry_micro_area!(code: "02", team: team) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def body(**over)
    { micro_area_id: area.id, property_type: "2", refused: false, contact_phone: "4133334444", address: registry_address }.merge(over)
  end

  def ficha_header(version)
    entry = LediOutboxEntry.find_by!(source_type: "HouseholdVersion", source_id: version.id)
    Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_domiciliar"), Ledi::Transport.read(entry.bytes).dadoSerializado).headerTransport
  end

  def commerce!
    sign_in_as(agent)
    json_post "/territory/households", body
    expect(response).to have_http_status(:created)
    Household.find(json_body["id"])
  end

  it "ACE cria comércio (tipo 2) na microárea atribuída → 201, versão com saved_cbo 515140 e ficha 3 gerada com o CBO 515140" do
    household = commerce!
    expect(json_body).to include("version" => 1, "property_type" => "2", "families" => [], "micro_area" => { "id" => area.id, "code" => area.code })
    version = household.latest_version
    expect(version).to have_attributes(saved_cbo: "515140", saved_by_user_id: agent.id, saved_by_professional_id: agent.professional.id)
    expect(ficha_header(version).cboCodigo_2002).to eq("515140")
    expect(DomainEvent.where(name: "household.saved").last.payload)
      .to eq("household_id" => household.id, "household_version_id" => version.id, "user_id" => agent.id)

    json_patch "/territory/households/#{household.id}", body(property_type: "4", version: 1)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("version" => 2, "property_type" => "4")
    expect(ficha_header(household.reload.latest_version).cboCodigo_2002).to eq("515140")
  end

  it "ACE cria domicílio (tipo 1) → 403 cbo_not_allowed" do
    sign_in_as(agent)
    json_post "/territory/households", body(property_type: "1", living_conditions: registry_living_conditions)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(Household.count).to eq(0)
  end

  it "ACE edita o comércio para tipo 1 → 403 cbo_not_allowed, nada gravado" do
    household = commerce!
    versions = HouseholdVersion.count
    json_patch "/territory/households/#{household.id}", body(property_type: "1", living_conditions: registry_living_conditions, version: 1)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(HouseholdVersion.count).to eq(versions)
    expect(household.reload).to have_attributes(version: 1)
    expect(LediOutboxEntry.where(source_type: "HouseholdVersion").count).to eq(1)
  end

  it "ACE edita um residencial existente → 403 cbo_not_allowed" do
    household = registry_household!(micro_area: area)
    sign_in_as(agent)
    json_patch "/territory/households/#{household.id}", registry_household_params(household).merge("version" => 1)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    json_patch "/territory/households/#{household.id}", body(version: 1)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(household.reload.version).to eq(1)
  end

  it "ACE cria família no comércio ou cadastro individual → 403 cbo_not_allowed" do
    household = commerce!
    patient = registry_patient!
    json_post "/territory/households/#{household.id}/families", responsible: { patient_id: patient.id }, members_count: 1, version: 1
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    json_post "/territory/registrations", registry_registration_params(household, patient: patient)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    json_post "/territory/registrations", registry_registration_params(team, patient: patient)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(Family.count + IndividualRegistration.count).to eq(0)
    expect(household.reload.version).to eq(1)
  end

  it "gate desligado → 403 cbo_not_allowed" do
    household = commerce!
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    json_post "/territory/households", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    json_patch "/territory/households/#{household.id}", body(version: 1)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(Household.count).to eq(1)
  end

  it "microárea não atribuída → 403 out_of_scope" do
    sign_in_as(agent)
    json_post "/territory/households", body(micro_area_id: other_area.id)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    # Mover o comércio para microárea não atribuída também.
    household = commerce!
    json_patch "/territory/households/#{household.id}", body(micro_area_id: other_area.id, version: 1)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    expect(Household.where(micro_area_id: other_area.id)).to be_empty
  end

  it "TACS 515130 atribuído → 403 cbo_not_allowed" do
    tacs = field_agent!(cbo: "515130", team: team)
    assignment!(area, tacs.professional)
    sign_in_as(tacs)
    json_post "/territory/households", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(Household.count).to eq(0)
  end

  it "ACS sem mudança: cria o domicílio residencial na sua microárea" do
    acs = registry_acs!(unit, team: team)
    mine = registry_micro_area!(code: "01", team: team, acs: acs)
    sign_in_as(acs)
    json_post "/territory/households", body(micro_area_id: mine.id, property_type: "1", living_conditions: registry_living_conditions)
    expect(response).to have_http_status(:created)
    expect(Household.find(json_body["id"]).latest_version.saved_cbo).to eq("515105")
    json_post "/territory/households", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
  end
end
