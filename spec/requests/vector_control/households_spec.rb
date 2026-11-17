require "rails_helper"

# Módulo 35a (ADR 0054; contrato §2, §12, §17; Q2, Q8, Q13(5)): o imóvel na
# vigilância ambiental. A coordenação atribui o quarteirão em lote (até 200,
# tudo ou nada) e edita o perfil; a lista grava a trilha territory_registry e
# não traz morador; o perfil do imóvel serve ao agente nas microáreas dele.
# Nada disso escreve no 24a (nenhuma household_versions nova).
RSpec.describe "Vigilância ambiental — imóveis", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:other_neighborhood) { Neighborhood.create!(name: "Batel #{SecureRandom.hex(3)}", source: "manual") }
  let(:area) { registry_micro_area!(code: "01") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }

  def household!(neighborhood_id: neighborhood.id, micro_area: area)
    registry_household!(micro_area: micro_area, neighborhood_id: neighborhood_id)
  end

  def assign(ids, block_id = block.id) = json_post("/vector_control/households/assign_block", household_ids: ids, city_block_id: block_id)
  def profile_events = DomainEvent.where(name: "household_vector_profile.changed").order(:occurred_at)
  def trails = DomainEvent.where(name: "clinical_record.viewed")

  it "atribuição em lote de 3 → 200, três eventos, nenhuma `household_versions` nova; responde `{ assigned: 3 }`" do
    households = Array.new(3) { household! }
    vector_profile!(households.first, block: nil, risk: "red")
    versions = HouseholdVersion.count
    sign_in_as(coordinator)

    assign(households.map(&:id))
    expect([ response.status, json_body ]).to eq([ 200, { "assigned" => 3 } ])
    expect(HouseholdVersion.count).to eq(versions)
    expect(households.map { |household| household.reload.version }).to all(eq(1))
    profiles = HouseholdVectorProfile.where(household: households).index_by(&:household_id)
    expect(profiles.values.map(&:city_block_id)).to all(eq(block.id))
    expect(profiles.values.map(&:updated_by_user_id)).to all(eq(coordinator.id))
    expect(profiles[households.first.id]).to have_attributes(version: 2, risk_class: "red")
    expect(profiles[households.last.id].version).to eq(1)
    expect(profile_events.map(&:payload))
      .to match_array(households.map { |household| { "household_id" => household.id, "user_id" => coordinator.id } })
  end

  it "201 ids → 422 path household_ids" do
    sign_in_as(coordinator)
    assign(Array.new(201) { SecureRandom.uuid })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "household_ids" } ])
    assign([])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "household_ids" } ])
    assign([ household!.id, "h2" ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "household_ids[1]" } ])
    inactive = household!.tap { |household| household.update_columns(status: "inactive") }
    assign([ household!.id, inactive.id ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "household_ids[1]" } ])
    block.update!(active: false)
    assign([ household!.id ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "city_block_id" } ])
    expect(HouseholdVectorProfile.count).to eq(0)
  end

  it "imóvel sem `neighborhood_id` → 422 household_without_neighborhood path household_ids[1], nada gravado" do
    sign_in_as(coordinator)
    assign([ household!.id, household!(neighborhood_id: nil).id ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "household_without_neighborhood", "path" => "household_ids[1]" } ])
    expect(HouseholdVectorProfile.count).to eq(0)
    expect(profile_events).to be_empty
  end

  it "quarteirão de outro bairro → 422 block_not_in_household_neighborhood" do
    sign_in_as(coordinator)
    assign([ household!(neighborhood_id: other_neighborhood.id).id ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "block_not_in_household_neighborhood", "path" => "household_ids[0]" } ])
    expect(HouseholdVectorProfile.count).to eq(0)
  end

  it "domicílio que trocou de bairro no 24a aparece com `neighborhood_id` ≠ `block.neighborhood_id`" do
    household = household!
    vector_profile!(household, block: block)
    registry_new_household_version!(household, neighborhood_id: other_neighborhood.id)
    sign_in_as(coordinator)

    get "/vector_control/households", params: { city_block_id: block.id }
    row = json_body["items"].sole
    expect(row["neighborhood_id"]).to eq(other_neighborhood.id)
    expect(row["block"]).to eq("id" => block.id, "number" => "12", "neighborhood_id" => neighborhood.id)
  end

  it "lista de quarteirões com `households_count` e `neighborhood { id, name }`" do
    vector_profile!(household!, block: block)
    vector_profile!(household!, block: block)
    vector_profile!(household!.tap { |household| household.update_columns(status: "inactive") }, block: block)
    empty = city_block!(neighborhood: neighborhood, number: "13")
    sign_in_as(coordinator)

    get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id }
    counts = json_body["items"].to_h { |item| [ item["id"], item["households_count"] ] }
    expect(counts).to eq(block.id => 2, empty.id => 0)
    expect(json_body["items"].map { |item| item["neighborhood"] }).to all(eq("id" => neighborhood.id, "name" => neighborhood.name))
  end

  it "PATCH profile com risco grava `risk_assessed_on` de hoje" do
    household = household!
    sign_in_as(coordinator)
    json_patch "/vector_control/households/#{household.id}/profile", risk_class: "yellow", city_block_id: block.id
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => household.id, "risk_class" => "yellow", "risk_assessed_on" => Time.zone.today.iso8601,
                                 "block" => { "id" => block.id, "number" => "12", "neighborhood_id" => neighborhood.id })
    profile = HouseholdVectorProfile.find_by!(household: household)
    expect(profile).to have_attributes(risk_class: "yellow", risk_assessed_on: Time.zone.today, version: 1,
                                       updated_by_user_id: coordinator.id)

    json_patch "/vector_control/households/#{household.id}/profile", risk_class: nil
    expect(json_body).to include("risk_class" => nil, "risk_assessed_on" => nil)
    expect(profile.reload.version).to eq(2)
    json_patch "/vector_control/households/#{household.id}/profile", risk_class: "blue"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "risk_class" } ])
    json_patch "/vector_control/households/#{household.id}/profile", city_block_id: city_block!(neighborhood: other_neighborhood, number: "1").id
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "block_not_in_household_neighborhood", "path" => "city_block_id" } ])
    expect(profile_events.count).to eq(2)
  end

  it "a lista grava a trilha territory_registry com os ids mostrados e não traz morador" do
    first = household!
    second = household!(micro_area: registry_micro_area!(code: "02", team: area.team))
    vector_profile!(second, block: block, risk: "green")
    sign_in_as(coordinator)

    get "/vector_control/households", params: { neighborhood_id: neighborhood.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    items = json_body["items"].index_by { |item| item["id"] }
    expect(items.keys).to contain_exactly(first.id, second.id)
    expect(items[first.id]).to eq("id" => first.id, "address_short" => "Rua das Flores, 120", "property_type" => "1",
                                  "neighborhood_id" => neighborhood.id, "micro_area" => { "id" => area.id, "code" => "01" },
                                  "block" => nil, "risk_class" => nil, "risk_assessed_on" => nil, "last_worked_on" => nil,
                                  "last_situation" => nil)
    expect(items[second.id]).to include("risk_class" => "green", "block" => { "id" => block.id, "number" => "12",
                                                                              "neighborhood_id" => neighborhood.id })
    expect(json_body["items"].flat_map(&:keys).uniq).to match_array(%w[id address_short property_type neighborhood_id micro_area block
                                                                         risk_class risk_assessed_on last_worked_on last_situation])
    expect(trails.map(&:payload)).to contain_exactly(
      { "access" => "territory_registry", "micro_area_id" => area.id, "household_ids" => [ first.id ], "user_id" => coordinator.id },
      { "access" => "territory_registry", "micro_area_id" => second.micro_area_id, "household_ids" => [ second.id ],
        "user_id" => coordinator.id }
    )

    get "/vector_control/households", params: { neighborhood_id: neighborhood.id, without_block: "true" }
    expect(json_body["items"].map { |item| item["id"] }).to eq([ first.id ])

    sign_in_as(endemic_agent!)
    get "/vector_control/households", params: { neighborhood_id: neighborhood.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    assign([ first.id ])
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "GET /households/:id: ACE na microárea atribuída → `{ id, neighborhood_id, vector }`; em outra microárea → 404; ACS → 403 cbo_not_allowed; sem trilha" do
    agent = endemic_agent!
    agent_area = MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area
    mine = household!(micro_area: agent_area)
    profiled = household!(micro_area: agent_area)
    vector_profile!(profiled, block: block, risk: "purple")
    elsewhere = household!(micro_area: registry_micro_area!(code: "05", team: agent_area.team))

    sign_in_as(agent)
    get "/vector_control/households/#{mine.id}"
    expect([ response.status, json_body ]).to eq([ 200, { "id" => mine.id, "neighborhood_id" => neighborhood.id, "vector" => nil } ])
    get "/vector_control/households/#{profiled.id}"
    expect(json_body).to eq("id" => profiled.id, "neighborhood_id" => neighborhood.id,
                            "vector" => { "city_block_id" => block.id, "risk_class" => "purple",
                                          "risk_assessed_on" => Time.zone.today.iso8601, "last_worked_on" => nil, "last_situation" => nil })
    get "/vector_control/households/#{elsewhere.id}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    sign_in_as(coordinator)
    get "/vector_control/households/#{elsewhere.id}"
    expect(json_body).to eq("id" => elsewhere.id, "neighborhood_id" => neighborhood.id, "vector" => nil)

    sign_in_as(registry_acs_of(agent_area))
    get "/vector_control/households/#{mine.id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    expect(trails).to be_empty
  end
end
