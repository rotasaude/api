require "rails_helper"

# Módulo 35b, Task 7 (ADR 0054; contrato §3, §9, §10): /zoonoses/campaigns.
# Leitura reader? (a equipe, a coordenação, o municipal_admin); escrita só a
# coordenação (403 missing_role). Metas ausentes → round(estimativa ×
# rabies_coverage_target), sem estimativa → 422 path goal_dogs. PATCH só em
# planned (409 invalid_transition path status) e com expected_version (409
# campaign_changed). Uma campanha open por vez (409 campaign_already_open); a
# etapa só anda planned → open → closed.
RSpec.describe "Zoonoses — campanhas", type: :request do
  let!(:city) { zoonoses_city! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }
  let(:body) { { name: "Campanha 2026", starts_on: (today + 1).iso8601, ends_on: (today + 30).iso8601 } }

  def create_campaign(fields) = post("/zoonoses/campaigns", params: fields.to_json, headers: headers)
  def edit(id, fields) = patch("/zoonoses/campaigns/#{id}", params: fields.to_json, headers: headers)
  def open_campaign(id) = post("/zoonoses/campaigns/#{id}/open", headers: headers)
  def close_campaign(id) = post("/zoonoses/campaigns/#{id}/close", headers: headers)

  def estimate!(dogs:, cats:)
    ZoonosesParameterVersion.create!(version: 1, values: { "dog_population_estimate" => dogs, "cat_population_estimate" => cats },
                                     created_by_user: coordinator)
  end

  it "zoonoses_team cria → 403; coordenação cria com meta sugerida pela estimativa" do
    sign_in_as(zoonoses_team!)
    create_campaign(body.merge(goal_dogs: 10, goal_cats: 5))
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    estimate!(dogs: 1001, cats: 333)
    sign_in_as(coordinator)
    create_campaign(body)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("name" => "Campanha 2026", "year" => (today + 1).year, "starts_on" => (today + 1).iso8601,
                                 "ends_on" => (today + 30).iso8601, "goal_dogs" => 801, "goal_cats" => 266, "stage" => "planned",
                                 "version" => 1)
    campaign = RabiesCampaign.find(json_body["id"])
    expect(DomainEvent.where(name: "rabies_campaign.changed").sole.payload).to eq("rabies_campaign_id" => campaign.id)

    create_campaign(body.merge(goal_dogs: 7, goal_cats: 0))
    expect(json_body).to include("goal_dogs" => 7, "goal_cats" => 0)
  end

  it "sem estimativa e sem metas → 422 path goal_dogs; recusas de campo com o path" do
    sign_in_as(coordinator)
    create_campaign(body)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "goal_dogs" } ])
    create_campaign(body.merge(goal_dogs: 10))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "goal_cats" } ])
    create_campaign(body.merge(goal_dogs: 10, goal_cats: 5, ends_on: today.iso8601))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "ends_on" } ])
    create_campaign(body.merge(goal_dogs: -1, goal_cats: 5))
    expect(json_body).to eq("error" => "invalid_request", "path" => "goal_dogs")
    create_campaign(body.merge(name: "a" * 81, goal_dogs: 1, goal_cats: 1))
    expect(json_body).to eq("error" => "invalid_request", "path" => "name")
    create_campaign(body.merge(goal_dogs: 1, goal_cats: 1, stage: "open"))
    expect(json_body).to eq("error" => "invalid_request", "path" => "stage")
    post "/zoonoses/campaigns?name=x", params: body.merge(goal_dogs: 1, goal_cats: 1).to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(RabiesCampaign.count).to eq(0)
  end

  it "abrir a segunda → 409 campaign_already_open; fechar a primeira libera" do
    sign_in_as(coordinator)
    first, second = Array.new(2) do
      create_campaign(body.merge(goal_dogs: 10, goal_cats: 5))
      json_body["id"]
    end
    open_campaign(first)
    expect(json_body).to include("stage" => "open", "version" => 2)
    open_campaign(second)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "campaign_already_open" } ])
    close_campaign(first)
    expect(json_body).to include("stage" => "closed", "version" => 3)
    open_campaign(second)
    expect(json_body).to include("stage" => "open")
    expect(DomainEvent.where(name: "rabies_campaign.changed").count).to eq(5)
  end

  it "closed → open → 409 invalid_transition path status; planned → close → 409; corpo no open → 422" do
    sign_in_as(coordinator)
    create_campaign(body.merge(goal_dogs: 10, goal_cats: 5))
    id = json_body["id"]
    close_campaign(id)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    post "/zoonoses/campaigns/#{id}/open", params: { stage: "open" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "stage" } ])
    open_campaign(id)
    close_campaign(id)
    open_campaign(id)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    open_campaign(SecureRandom.uuid)
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "PATCH: expected_version ausente → 422; divergente → 409 campaign_changed; fora de planned → 409 invalid_transition" do
    sign_in_as(coordinator)
    create_campaign(body.merge(goal_dogs: 10, goal_cats: 5))
    id = json_body["id"]
    edit(id, goal_dogs: 20)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    edit(id, goal_dogs: 20, expected_version: 2)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "campaign_changed" } ])
    edit(id, goal_dogs: 20, name: "Campanha de outubro", expected_version: 1)
    expect(json_body).to include("goal_dogs" => 20, "goal_cats" => 5, "name" => "Campanha de outubro", "version" => 2)
    edit(id, ends_on: (today - 1).iso8601, expected_version: 2)
    expect(json_body).to eq("error" => "invalid_request", "path" => "ends_on")

    open_campaign(id)
    edit(id, goal_dogs: 30, expected_version: 3)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    expect(RabiesCampaign.find(id).goal_dogs).to eq(20)
  end

  it "GET /zoonoses/campaigns: municipal_admin e a equipe leem; outro papel → 403" do
    RabiesCampaign.create!(name: "Antiga", year: today.year, starts_on: today - 90, ends_on: today - 60, goal_dogs: 1, goal_cats: 1,
                           stage: "closed")
    RabiesCampaign.create!(name: "Nova", year: today.year, starts_on: today + 1, ends_on: today + 30, goal_dogs: 1, goal_cats: 1)
    [ staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"), zoonoses_team! ].each do |reader|
      sign_in_as(reader)
      get "/zoonoses/campaigns"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].pluck("name")).to eq(%w[Nova Antiga])
    end
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/campaigns"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
