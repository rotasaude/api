require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, §10, §16): /zoonoses/leish_tests
# e /zoonoses/leish_outcomes, para team? (403 missing_role). A coleta volta com
# a etiqueta; a correção leva expected_version (409 test_changed); a lista
# filtra por inquérito e pendência (elisa: DPP reagente sem ELISA; outcome:
# reagente nos dois sem desfecho) e nunca traz o tutor (só has_tutor).
RSpec.describe "Zoonoses — sorologia e desfecho da leishmaniose", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:survey) { leish_survey!(blocks: [ block ], starts_on: today - 10) }
  let(:seq) { [ 0 ] }

  def test!(animal: animal!(tutor: tutor!), dpp: "reactive", elisa: "reactive", survey: self.survey)
    seq[0] += 1
    LeishTest.create!(leish_survey: survey, animal: animal, collected_on: today - 3, label: "LV-#{today.year}-AVUL-#{format('%04d', seq[0])}",
                      dpp_result: dpp, dpp_on: (today - 3 if dpp), elisa_result: elisa, elisa_on: (today - 1 if elisa))
  end

  it "coleta → 201 com a etiqueta; correção → a versão nova; versão velha → 409 test_changed; outro papel → 403" do
    dog = animal!(name: "Thor")
    sign_in_as(team)
    json_post "/zoonoses/leish_tests", leish_survey_id: survey.id, animal_id: dog.id, collected_on: today.iso8601,
                                       dpp_result: "reactive", dpp_on: today.iso8601
    expect(response).to have_http_status(:created)
    expect(response.body).not_to include("Thor")
    expect(json_body).to include("leish_survey_id" => survey.id, "label" => "LV-#{today.year}-#{survey.id.delete('-')[0, 6].upcase}-0001",
                                 "animal" => { "id" => dog.id, "has_tutor" => false }, "collected_on" => today.iso8601,
                                 "dpp_result" => "reactive", "dpp_on" => today.iso8601, "elisa_result" => nil, "version" => 1,
                                 "outcome" => nil)
    id = json_body["id"]

    json_patch "/zoonoses/leish_tests/#{id}", elisa_result: "reactive", elisa_on: today.iso8601, elisa_request: "GAL-1", expected_version: 1
    expect(json_body).to include("elisa_result" => "reactive", "elisa_request" => "GAL-1", "version" => 2)
    json_patch "/zoonoses/leish_tests/#{id}", elisa_result: "non_reactive", expected_version: 1
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "test_changed" } ])
    json_post "/zoonoses/leish_tests", animal_id: dog.id, collected_on: today.iso8601, elisa_result: "reactive", elisa_on: today.iso8601
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "elisa_without_reactive_dpp", "path" => "elisa_result" } ])
    json_patch "/zoonoses/leish_tests/#{SecureRandom.uuid}", dpp_result: "invalid", expected_version: 1
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/leish_tests"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "lista de desfecho pendente traz só os reagentes sem desfecho, sem tutor" do
    pending = test!
    decided = test!
    LeishDogOutcome.create!(animal: decided.animal, leish_test: decided, decision: "tutor_treatment", decided_on: today)
    elisa_due = test!(elisa: nil)
    negative = test!(dpp: "reactive", elisa: "non_reactive")
    test!(dpp: "non_reactive", elisa: nil)
    other_survey = test!(survey: leish_survey!(blocks: [ block ]))

    sign_in_as(team)
    get "/zoonoses/leish_tests", params: { pending: "outcome" }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id")).to contain_exactly(pending.id, other_survey.id)
    get "/zoonoses/leish_tests", params: { pending: "outcome", survey_id: survey.id }
    expect(json_body["items"].pluck("id")).to eq([ pending.id ])
    item = json_body["items"].first
    expect(item["animal"]).to eq("id" => pending.animal_id, "has_tutor" => true)
    expect(response.body).not_to include(ZoonosesHelpers::ZOONOSES_TUTOR_NAME)
    expect(response.body).not_to include(pending.animal.tutor_patient_id)

    get "/zoonoses/leish_tests", params: { pending: "elisa" }
    expect(json_body["items"].pluck("id")).to eq([ elisa_due.id ])
    get "/zoonoses/leish_tests", params: { survey_id: survey.id }
    expect(json_body["items"].size).to eq(5)
    expect(json_body["items"].pluck("id")).to include(negative.id, decided.id)
    expect(json_body["items"].find { _1["id"] == decided.id }["outcome"]).to include("decision" => "tutor_treatment")

    get "/zoonoses/leish_tests", params: { pending: "tudo" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "pending" } ])
    get "/zoonoses/leish_tests", params: { survey_id: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "survey_id" } ])
    get "/zoonoses/leish_tests", params: { tutor: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "paginação pela criação, mais recente primeiro" do
    tests = Array.new(3) { test! }
    sign_in_as(team)
    get "/zoonoses/leish_tests", params: { limit: 2 }
    expect(json_body["items"].pluck("id")).to eq(tests.reverse.first(2).map(&:id))
    get "/zoonoses/leish_tests", params: { limit: 2, before: json_body["next_before"] }
    expect(json_body["items"].pluck("id")).to eq([ tests.first.id ])
    expect(json_body["next_before"]).to be_nil
  end

  it "POST /zoonoses/leish_outcomes: 201 com o desfecho, sem a nota; refused sem tutor → 422 path decision" do
    test = test!
    sign_in_as(team)
    json_post "/zoonoses/leish_outcomes", leish_test_id: test.id, decision: "refused", decided_on: today.iso8601,
                                          note: "Tutor recusou o tratamento e a eutanásia."
    expect(response).to have_http_status(:created)
    expect(json_body).to include("leish_test_id" => test.id, "animal_id" => test.animal_id, "decision" => "refused",
                                 "decided_on" => today.iso8601, "euthanasia_id" => nil)
    expect(response.body).not_to include("recusou")

    community = test!(animal: animal!(community: true))
    json_post "/zoonoses/leish_outcomes", leish_test_id: community.id, decision: "refused", decided_on: today.iso8601
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "decision" } ])
    post "/zoonoses/leish_outcomes?decision=refused", params: { leish_test_id: community.id }.to_json,
                                                      headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end
end
