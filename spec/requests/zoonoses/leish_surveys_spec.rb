require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, §10, Q8, Q18, Q21, Q28, Q32):
# /zoonoses/leish_surveys. Leitura reader?; escrita e sugestão só a
# coordenação (403 missing_role). target_dogs calculado pelo api (tabela de
# 2%, censo, foco = população com below_focus_min); quarteirões ativos do 35a
# mesmo sem o vector_control (Q8); draft → open → closed com expected_version
# (409 invalid_transition path status; 409 survey_changed). O detalhe traz os
# household_ids dos quarteirões (Q21), a sugestão de população (Q18) e a
# prevalência. POST …/suggest não grava (Q28) e, no foco, amplia os anéis até
# leish_focus_min_dogs, no máximo 5 (adendo do coordenador).
RSpec.describe "Zoonoses — inquéritos de leishmaniose", type: :request do
  let!(:city) { zoonoses_city! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:today) { Time.zone.today }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:body) do
    { name: "Inquérito 2026", kind: "sample", neighborhood_id: neighborhood.id, city_block_ids: [ block.id ], dog_population: 600,
      starts_on: today.iso8601, ends_on: (today + 60).iso8601 }
  end

  def household_in(block) = registry_household!.tap { |row| vector_profile!(row, block: block) }

  def dogs!(household, count) = Array.new(count) { animal!(household: household) }

  def suggest(fields) = json_post("/zoonoses/leish_surveys/suggest", fields)

  it "zoonoses_team cria → 403; coordenação cria sample com target da tabela; evento só com o id" do
    sign_in_as(zoonoses_team!)
    json_post "/zoonoses/leish_surveys", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    suggest(kind: "sample", neighborhood_id: neighborhood.id)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(coordinator)
    json_post "/zoonoses/leish_surveys", body
    expect(response).to have_http_status(:created)
    expect(json_body).to include("name" => "Inquérito 2026", "kind" => "sample", "neighborhood_id" => neighborhood.id,
                                 "neighborhood" => { "id" => neighborhood.id, "name" => neighborhood.name },
                                 "city_block_ids" => [ block.id ], "dog_population" => 600, "target_dogs" => 334,
                                 "below_focus_min" => false, "stage" => "draft", "version" => 1, "parameters_version" => 0,
                                 "household_ids" => [], "dog_population_suggested" => 16,
                                 "prevalence" => { "examined" => 0, "reactive" => 0, "prevalence" => nil })
    survey = LeishSurvey.find(json_body["id"])
    expect(survey).to have_attributes(target_dogs: 334, parameters_version: 0)
    expect(DomainEvent.where(name: "leish_survey.changed").sole.payload).to eq("leish_survey_id" => survey.id)

    json_post "/zoonoses/leish_surveys", body.merge(dog_population: 499)
    expect(json_body).to include("target_dogs" => 499) # Q32: abaixo de 500, censo
    json_post "/zoonoses/leish_surveys", body.merge(kind: "focus", dog_population: 40)
    expect(json_body).to include("target_dogs" => 40, "below_focus_min" => true)
    json_post "/zoonoses/leish_surveys", body.merge(kind: "census", dog_population: 250)
    expect(json_body).to include("target_dogs" => 250, "below_focus_min" => false)
  end

  it "recusas de campo com o path; texto longo recusado; query recusada" do
    sign_in_as(coordinator)
    inactive = city_block!(neighborhood: neighborhood, number: "9").tap { _1.update!(active: false) }
    {
      { city_block_ids: [] } => "city_block_ids", { city_block_ids: [ SecureRandom.uuid ] } => "city_block_ids",
      { city_block_ids: [ inactive.id ] } => "city_block_ids", { city_block_ids: "x" } => "city_block_ids",
      { name: "a" * 81 } => "name", { kind: "sorteio" } => "kind", { neighborhood_id: SecureRandom.uuid } => "neighborhood_id",
      { dog_population: 0 } => "dog_population", { dog_population: "600" } => "dog_population",
      { ends_on: (today - 1).iso8601 } => "ends_on", { target_dogs: 10 } => "target_dogs", { stage: "open" } => "stage"
    }.each do |over, path|
      json_post "/zoonoses/leish_surveys", body.merge(over)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => path } ]), over.inspect
    end
    json_post "/zoonoses/leish_surveys", body.except(:dog_population)
    expect(json_body).to eq("error" => "invalid_request", "path" => "dog_population")
    post "/zoonoses/leish_surveys?name=x", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(LeishSurvey.count).to eq(0)
  end

  it "cidade sem vector_control usa os quarteirões do 35a (Q8)" do
    expect(Platform::Features.enabled?(city, VectorControl::Gate::KEY)).to be(false)
    sign_in_as(coordinator)
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12"
    expect(response).to have_http_status(:created)
    created = json_body["id"]

    suggest(kind: "census", neighborhood_id: neighborhood.id)
    expect(json_body).to eq("city_block_ids" => [ created ], "dog_population_suggested" => 16, "target_dogs" => 16, "below_focus_min" => false)
    json_post "/zoonoses/leish_surveys", body.merge(city_block_ids: [ created ])
    expect(response).to have_http_status(:created)
    expect(json_body["city_block_ids"]).to eq([ created ])
  end

  it "draft → closed → 409 invalid_transition; draft → open → closed com expected_version; PATCH só em draft" do
    sign_in_as(coordinator)
    json_post "/zoonoses/leish_surveys", body
    id = json_body["id"]
    json_post "/zoonoses/leish_surveys/#{id}/close", expected_version: 1
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    json_post "/zoonoses/leish_surveys/#{id}/open", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])

    json_patch "/zoonoses/leish_surveys/#{id}", dog_population: 700
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    json_patch "/zoonoses/leish_surveys/#{id}", dog_population: 700, expected_version: 2
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "survey_changed" } ])
    json_patch "/zoonoses/leish_surveys/#{id}", dog_population: 700, expected_version: 1
    expect(json_body).to include("dog_population" => 700, "target_dogs" => 363, "version" => 2)

    json_post "/zoonoses/leish_surveys/#{id}/open", expected_version: 1
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "survey_changed" } ])
    json_post "/zoonoses/leish_surveys/#{id}/open", expected_version: 2
    expect(json_body).to include("stage" => "open", "version" => 3)
    json_patch "/zoonoses/leish_surveys/#{id}", name: "Outro", expected_version: 3
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    json_post "/zoonoses/leish_surveys/#{id}/open", expected_version: 3
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    json_post "/zoonoses/leish_surveys/#{id}/close", expected_version: 3, stage: "closed"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "stage" } ])
    json_post "/zoonoses/leish_surveys/#{id}/close", expected_version: 3
    expect(json_body).to include("stage" => "closed", "version" => 4)
    expect(DomainEvent.where(name: "leish_survey.changed").count).to eq(4)
    json_post "/zoonoses/leish_surveys/#{SecureRandom.uuid}/open", expected_version: 1
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "GET: lista e detalhe para reader?; detalhe com household_ids, sugestão pelos cães ativos e prevalência" do
    household = household_in(block)
    dogs!(household, 3)
    animal!(household: household, species: "cat")
    animal!(household: household, status: "missing")
    household_in(city_block!(neighborhood: neighborhood, number: "2")).then { dogs!(_1, 5) }
    survey = leish_survey!(blocks: [ block ], dog_population: 30, target_dogs: 30)
    LeishTest.create!(leish_survey: survey, animal: animal!, collected_on: today, label: "LV-#{today.year}-AVUL-0001",
                      dpp_result: "non_reactive", dpp_on: today)
    LeishTest.create!(leish_survey: survey, animal: animal!, collected_on: today, label: "LV-#{today.year}-AVUL-0002",
                      dpp_result: "reactive", dpp_on: today, elisa_result: "reactive", elisa_on: today)

    [ staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"), zoonoses_team! ].each do |reader|
      sign_in_as(reader)
      get "/zoonoses/leish_surveys"
      expect(json_body["items"].pluck("id")).to eq([ survey.id ])
      expect(json_body["items"].first).not_to have_key("household_ids")
      get "/zoonoses/leish_surveys/#{survey.id}"
      expect(json_body).to include("household_ids" => [ household.id ], "dog_population_suggested" => 3,
                                   "prevalence" => { "examined" => 2, "reactive" => 1, "prevalence" => 50.0 })
    end
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/leish_surveys"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  describe "POST /zoonoses/leish_surveys/suggest (Q28)" do
    before { sign_in_as(coordinator) }

    it "sample/census: os quarteirões ativos do bairro; sem cão, quarteirões × dogs_per_block; com cães, os ativos; não grava" do
      second = city_block!(neighborhood: neighborhood, number: "2")
      block
      city_block!(neighborhood: neighborhood, number: "3").update!(active: false)
      city_block!(neighborhood: Neighborhood.create!(name: "Outro #{SecureRandom.hex(2)}", source: "manual"), number: "1")
      suggest(kind: "sample", neighborhood_id: neighborhood.id)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("city_block_ids" => [ block.id, second.id ], "dog_population_suggested" => 32, "target_dogs" => 32,
                              "below_focus_min" => false)

      dogs!(household_in(second), 2)
      suggest(kind: "census", neighborhood_id: neighborhood.id)
      expect(json_body).to include("dog_population_suggested" => 2, "target_dogs" => 2)
      expect(LeishSurvey.count).to eq(0)
      expect(DomainEvent.where(name: "leish_survey.changed")).to be_empty
    end

    it "focus: 40 cães no central com vizinhos bastantes → amplia os anéis até ≥ 100 (below_focus_min false)" do
      ring1 = city_block!(neighborhood: neighborhood, number: "2")
      ring2 = city_block!(neighborhood: neighborhood, number: "3")
      ring3 = city_block!(neighborhood: neighborhood, number: "4")
      block_neighbors!(block, ring1)
      block_neighbors!(ring1, ring2)
      block_neighbors!(ring2, ring3)
      [ block, ring1, ring2, ring3 ].each { dogs!(household_in(_1), 40) }

      suggest(kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: block.id)
      expect(json_body).to include("dog_population_suggested" => 120, "target_dogs" => 120, "below_focus_min" => false)
      expect(json_body["city_block_ids"]).to contain_exactly(block.id, ring1.id, ring2.id)

      # `rings` explícito é o ponto de partida (a ampliação segue dali até 5).
      suggest(kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: block.id, rings: 3)
      expect(json_body).to include("dog_population_suggested" => 160, "target_dogs" => 160)
      expect(json_body["city_block_ids"]).to contain_exactly(block.id, ring1.id, ring2.id, ring3.id)

      # O rascunho com o central e `rings` reproduz a sugestão (mesmo sentido do suggest).
      json_post "/zoonoses/leish_surveys", body.except(:city_block_ids).merge(kind: "focus", center_city_block_id: block.id, rings: 3,
                                                                             dog_population: 160)
      expect(response).to have_http_status(:created)
      expect(json_body["city_block_ids"]).to contain_exactly(block.id, ring1.id, ring2.id, ring3.id)
      json_post "/zoonoses/leish_surveys", body.except(:city_block_ids).merge(kind: "focus", center_city_block_id: block.id, dog_population: 120)
      expect(json_body["city_block_ids"]).to contain_exactly(block.id, ring1.id, ring2.id)
      json_post "/zoonoses/leish_surveys", body.except(:city_block_ids).merge(kind: "focus", center_city_block_id: block.id, rings: 6,
                                                                             dog_population: 120)
      expect(json_body).to eq("error" => "invalid_request", "path" => "rings")
      json_post "/zoonoses/leish_surveys", body.merge(kind: "focus", rings: 2)
      expect(json_body).to eq("error" => "invalid_request", "path" => "rings")
    end

    it "focus: 40 cães sem vizinhos → below_focus_min true com o central" do
      household = household_in(block)
      dogs!(household, 40)
      suggest(kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: block.id)
      expect(json_body).to eq("city_block_ids" => [ block.id ], "dog_population_suggested" => 40, "target_dogs" => 40,
                              "below_focus_min" => true)

      # O rascunho do foco com o central grava os quarteirões da mesma sugestão.
      json_post "/zoonoses/leish_surveys", body.except(:city_block_ids).merge(kind: "focus", center_city_block_id: block.id, dog_population: 40)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("city_block_ids" => [ block.id ], "target_dogs" => 40, "below_focus_min" => true,
                                   "dog_population_suggested" => 40, "household_ids" => [ household.id ])
      json_post "/zoonoses/leish_surveys", body.merge(center_city_block_id: block.id)
      expect(json_body).to eq("error" => "invalid_request", "path" => "center_city_block_id")
      json_post "/zoonoses/leish_surveys", body.except(:city_block_ids).merge(center_city_block_id: block.id)
      expect(json_body).to eq("error" => "invalid_request", "path" => "center_city_block_id")
    end

    it "recusas: focus sem central, central inativo, rings fora de 0–5, rings fora do focus, chave estranha" do
      inactive = city_block!(neighborhood: neighborhood, number: "8").tap { _1.update!(active: false) }
      {
        { kind: "focus", neighborhood_id: neighborhood.id } => "center_city_block_id",
        { kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: inactive.id } => "center_city_block_id",
        { kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: block.id, rings: 6 } => "rings",
        { kind: "focus", neighborhood_id: neighborhood.id, center_city_block_id: block.id, rings: "1" } => "rings",
        { kind: "sample", neighborhood_id: neighborhood.id, rings: 1 } => "rings",
        { kind: "sample", neighborhood_id: neighborhood.id, center_city_block_id: block.id } => "center_city_block_id",
        { kind: "sample" } => "neighborhood_id", { neighborhood_id: neighborhood.id } => "kind",
        { kind: "sample", neighborhood_id: neighborhood.id, dog_population: 3 } => "dog_population"
      }.each do |fields, path|
        suggest(fields)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => path } ]), fields.inspect
      end
    end
  end
end
