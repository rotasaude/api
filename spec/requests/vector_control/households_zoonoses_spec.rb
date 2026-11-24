require "rails_helper"

# Módulo 35b, Q39 (opção A): na cidade só com o zoonoses (sem o
# vector_control), a coordenação liga o domicílio ao quarteirão pelas rotas
# do 35a — a lista, a atribuição em lote e o PATCH do perfil abrem com o
# require_vector_supplies!. Sem o vector_control, o PATCH aceita só
# city_block_id: o risco → 403 feature_disabled feature vector_control. O
# GET /households/:id (o `vector` do agente) e o `<household>.vector` do app
# continuam só com o vector_control. O domicílio ligado entra no inquérito
# (SurveyArea), no feed do tablet (leish_survey.household_ids) e na coleira
# do relatório leish.
RSpec.describe "Vigilância ambiental — imóveis na cidade só com zoonoses (Q39)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { zoonoses_city! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:today) { Time.zone.today }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def household! = registry_household!(micro_area: area, neighborhood_id: neighborhood.id)
  def assign(ids, block_id = block.id) = json_post("/vector_control/households/assign_block", household_ids: ids, city_block_id: block_id)

  it "o gate: zoonoses utilizável e vector_control desligado" do
    expect([ Zoonoses::Gate.usable?(city), VectorControl::Gate.usable?(city) ]).to eq([ true, false ])
  end

  it "liga o domicílio ao quarteirão (lote e perfil) e lista; o inquérito, o tablet e o relatório leish o encontram" do
    linked = household!
    patched = household!
    sign_in_as(coordinator)

    assign([ linked.id ])
    expect([ response.status, json_body ]).to eq([ 200, { "assigned" => 1 } ])
    json_patch "/vector_control/households/#{patched.id}/profile", city_block_id: block.id
    expect(response).to have_http_status(:ok)
    expect(HouseholdVectorProfile.where(household_id: [ linked.id, patched.id ]).pluck(:city_block_id)).to all(eq(block.id))

    get "/vector_control/households", params: { city_block_id: block.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |row| row["id"] }).to match_array([ linked.id, patched.id ])

    survey = leish_survey!(blocks: [ block ])
    expect(Zoonoses::SurveyArea.household_ids([ block.id ])).to match_array([ linked.id, patched.id ])

    travel(3.seconds) { get("/field/v1/changes", headers: { "Authorization" => "Bearer #{token}" }) }
    expect(response).to have_http_status(:ok)
    feed = json_body.fetch("items").find { |item| item["type"] == "leish_survey" && item["id"] == survey.id }
    expect(feed&.dig("body", "household_ids")).to match_array([ linked.id, patched.id ])

    dog = animal!(household: linked)
    collar!(animal: dog, placed_on: today)
    get "/zoonoses/reports/leish", params: { from: survey.starts_on.iso8601, to: today.iso8601, survey_id: survey.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["rows"].sole).to include("collars_placed" => 1, "collars_due" => 0)
  end

  it "sem o vector_control o PATCH só aceita city_block_id: risco → 403 feature_disabled feature vector_control, nada gravado" do
    household = household!
    sign_in_as(coordinator)
    json_patch "/vector_control/households/#{household.id}/profile", risk_class: "red"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
    json_patch "/vector_control/households/#{household.id}/profile", city_block_id: block.id, risk_class: "red"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
    expect(HouseholdVectorProfile.where(household_id: household.id)).to be_empty
    expect(DomainEvent.where(name: "household_vector_profile.changed")).to be_empty
  end

  it "o GET /households/:id continua só com o vector_control; sem nenhum dos dois, a lista e a atribuição → 403 feature vector_control" do
    household = household!
    sign_in_as(coordinator)
    get "/vector_control/households/#{household.id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/vector_control/households"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
    assign([ household.id ])
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
    json_patch "/vector_control/households/#{household.id}/profile", city_block_id: block.id
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
  end

  it "o papel não muda: zoonoses_team (sem a coordenação) → 403 missing_role" do
    sign_in_as(zoonoses_team!)
    get "/vector_control/households"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    assign([ household!.id ])
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
