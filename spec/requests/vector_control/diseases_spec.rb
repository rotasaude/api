require "rails_helper"

# Módulo 35a (Q38): GET /vector_control/diseases dá os rótulos das doenças de
# block_diseases e do bloqueio de transmissão. `items` = a lista da cidade do
# módulo 25 (Surveillance::Diseases.all, a mesma do /surveillance/diseases,
# na mesma ordem) só com código e nome; `groups` = os rótulos do 35a
# (VectorControl::Catalog::DISEASE_GROUP_LABELS). Só a coordenação e o
# municipal_admin; o gate é o do 35a, nunca o da vigilância.
RSpec.describe "Vigilância ambiental — doenças", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:groups) { [ { "code" => "arbovirus", "label" => "Arboviroses (dengue, chikungunya, zika)" } ] }

  def expected_items = Surveillance::Diseases.all.map { |d| { "code" => d.code, "name" => d.name } }

  before do
    Surveillance::DiseaseList::Load.call
    LocalNotifiableDisease.create!(code: "local_agravo_teste", name: "Agravo local de teste", deadline: "weekly",
                                   repeat_after_days: 30, updated_by_user: coordinator)
    LocalNotifiableDisease.create!(code: "local_agravo_inativo", name: "Agravo local inativo", deadline: "weekly",
                                   repeat_after_days: 30, updated_by_user: coordinator, active: false)
  end

  it "a coordenação lê a lista com a vigilância DESLIGADA (só o 35a ligado)" do
    sign_in_as(coordinator)
    get "/surveillance/diseases"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "surveillance" } ]) # controle

    get "/vector_control/diseases"
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body.keys).to eq(%w[items groups])
    expect(body["items"]).to eq(expected_items)
    expect(body["items"].size).to be > 50
    expect(body["items"]).to include({ "code" => "dengue", "name" => "Dengue (casos)" },
                                     { "code" => "local_agravo_teste", "name" => "Agravo local de teste" })
    expect(body["items"].map { _1["code"] }).not_to include("local_agravo_inativo")
    expect(body["items"].map(&:keys).uniq).to eq([ %w[code name] ])
    expect(body["groups"]).to eq(groups)
  end

  it "o municipal_admin lê a mesma lista" do
    sign_in_as(municipal_admin!)
    get "/vector_control/diseases"
    expect([ response.status, json_body ]).to eq([ 200, { "items" => expected_items, "groups" => groups } ])
  end

  it "o ACE (515140), o TACS, o vector_lab e o profissional de saúde → 403 missing_role" do
    team = registry_team!
    [ endemic_agent!, field_agent!(cbo: "322255", team: team), vector_lab!, registry_nurse!(team: team) ].each do |user|
      sign_in_as(user)
      get "/vector_control/diseases"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  it "o 35a desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(coordinator)
    get "/vector_control/diseases"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  it "chave na query → 422 invalid_request" do
    sign_in_as(coordinator)
    get "/vector_control/diseases?group=arbovirus"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end
end
