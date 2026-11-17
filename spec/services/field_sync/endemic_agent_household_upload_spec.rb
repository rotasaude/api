require "rails_helper"

# Módulo 35a (ADR 0054; contrato §20 Q13(1), Q14(2)): o item `household` do
# app de campo chega ao mesmo TerritoryRegistry::SaveHousehold. Com
# vector_control utilizável, o agente de endemias (515140) grava imóvel não
# residencial nas microáreas atribuídas a ele; residencial, troca para
# residencial, família e cadastro individual → rejected cbo_not_allowed;
# domicílio de microárea não atribuída → rejected not_found (household_id).
# O ACS não muda. Respostas contra o upload-response-v1.
RSpec.describe "FieldSync::Upload — imóvel não residencial do agente de endemias", type: :model do
  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:device) { FieldDevices::Register.call(user: agent, name: "Tablet").payload.fetch(:device) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }
  def upload(*items, user: agent, dev: device) = FieldSync::Upload.call(items: items, device: dev, user: user)
  def failure(result) = result.slice("status", "error", "path")
  def cbo_refusal = { "status" => "rejected", "error" => "cbo_not_allowed" }

  def valid_response!(results)
    expect(FieldSync::Schemas.errors("upload-response-v1", { "results" => results }.as_json)).to eq([])
  end

  def household_body(**over)
    { "micro_area_id" => area.id, "property_type" => "4", "refused" => false, "contact_phone" => "4133334444",
      "address" => registry_address }.merge(over.stringify_keys)
  end

  def commerce!
    result = TerritoryRegistry::SaveHousehold.call(params: household_body(property_type: "2"), by: agent, vector_control: true)
    raise "comércio recusado: #{result.reason}" if result.failure?

    result.payload[:household]
  end

  it "item household tipo 4 do ACE → accepted com version" do
    uuid = SecureRandom.uuid
    result = upload(item("household", household_body, uuid: uuid)).sole
    valid_response!([ result ])
    household = Household.find(result["id"])
    expect(result).to eq("client_uuid" => uuid, "status" => "accepted", "type" => "household", "id" => household.id, "version" => 1)
    expect(household.latest_version).to have_attributes(property_type: "4", saved_cbo: "515140")
    expect(FieldSyncReceipt.find_by!(client_uuid: uuid)).to have_attributes(item_type: "household", result_id: household.id, user_id: agent.id)

    again = upload(item("household", household_body(property_type: "5", household_id: household.id, version: 1))).sole
    expect(again).to include("status" => "accepted", "id" => household.id, "version" => 2)
  end

  it "tipo 1, troca para tipo 1, item family e individual_registration do ACE → rejected cbo_not_allowed" do
    household = commerce!
    patient = registry_patient!
    living = { "living_conditions" => registry_living_conditions }
    results = upload(item("household", household_body(property_type: "1", **living)),
                     item("household", household_body(property_type: "1", household_id: household.id, version: 1, **living)),
                     item("family", { "household_id" => household.id, "version" => 1, "members_count" => 1, "income_band" => "3", "living_since" => "2026-11",
                                      "responsible" => { "patient_id" => patient.id } }),
                     item("individual_registration", registry_registration_params(household, patient: patient)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ cbo_refusal ] * 4)
    expect(household.reload.version).to eq(1)
    expect(Household.count).to eq(1)
    expect(Family.count + IndividualRegistration.count + FieldSyncReceipt.count).to eq(0)
  end

  it "gate desligado → rejected cbo_not_allowed" do
    household = commerce!
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    results = upload(item("household", household_body), item("household", household_body(household_id: household.id, version: 1)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ cbo_refusal ] * 2)
    expect(Household.count).to eq(1)
  end

  it "household_id de microárea não atribuída → rejected not_found path household_id; criar nela → rejected out_of_scope" do
    other = registry_micro_area!(code: "02", team: team)
    nurse = registry_nurse!(team.health_unit, team: team)
    foreign = TerritoryRegistry::SaveHousehold.call(params: household_body(micro_area_id: other.id), by: nurse).payload[:household]
    results = upload(item("household", household_body(micro_area_id: other.id, household_id: foreign.id, version: 1)),
                     item("household", household_body(micro_area_id: other.id)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "not_found", "path" => "household_id" },
                                                { "status" => "rejected", "error" => "out_of_scope" } ])
    expect(foreign.reload.version).to eq(1)
  end

  it "ACS sem mudança: household residencial accepted; o TACS segue cbo_not_allowed" do
    acs = field_agent!(team: team)
    mine = registry_micro_area!(code: "01", team: team, acs: acs)
    acs_device = FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device)
    result = upload(item("household", household_body(micro_area_id: mine.id, property_type: "1", living_conditions: registry_living_conditions)),
                    user: acs, dev: acs_device).sole
    valid_response!([ result ])
    expect(result).to include("status" => "accepted", "version" => 1)
    expect(Household.find(result["id"]).latest_version.saved_cbo).to eq("515105")

    tacs = field_agent!(cbo: "515130", team: team)
    assignment!(area, tacs.professional)
    tacs_device = FieldDevices::Register.call(user: tacs, name: "Tablet").payload.fetch(:device)
    refused = upload(item("household", household_body), user: tacs, dev: tacs_device).sole
    expect(failure(refused)).to eq(cbo_refusal)
  end
end
