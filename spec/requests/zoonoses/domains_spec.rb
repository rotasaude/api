require "rails_helper"
require "json_schemer"

# Módulo 35b, Task 16 (contrato §10, §11, Q10, Q11): GET /zoonoses/domains
# devolve exatamente Zoonoses::Json.domains: o `zoonoses_domains` da referência
# do app (contracts v1.4.0) mais as listas do domains.yml para o dashboard.
# Para reader? e o agente de campo; com o gate desligado → 403 feature_disabled.
RSpec.describe "Zoonoses — domínios", type: :request do
  # O esquema é o do contracts v1.4.0, em cópia verbatim (a presa em
  # config/field_sync/ vem na Task 20, que então aposenta esta).
  let(:contracts) { Rails.root.join("spec/fixtures/field_sync_v1_4_0") }
  let(:reference_keys) { %w[species sexes sizes animal_statuses dpp_results products open_campaign parameters limits] }
  let!(:city) { zoonoses_city! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:labels) { YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")) }
  let(:today) { Time.zone.today }

  def open_campaign!(**over)
    RabiesCampaign.create!({ name: "Campanha #{SecureRandom.hex(3)}", year: today.year, starts_on: today - 5, ends_on: today + 20,
                             goal_dogs: 10, goal_cats: 5, stage: "open" }.merge(over))
  end

  it "o corpo bate com Zoonoses::Json.domains; produto inativo e de outra finalidade fora; sem campanha open → null" do
    vaccine = zoonoses_product!(code: "RAB")
    collar = zoonoses_product!(use: "collar", code: "COL")
    zoonoses_product!(code: "OLD").update!(active: false)
    vector_product!(code: "FOC", uses: [ "focal" ])
    open_campaign!(stage: "planned")
    sign_in_as(coordinator)

    get "/zoonoses/domains"
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body).to eq(JSON.parse(Zoonoses::Json.domains.to_json))
    expect(body["products"]).to eq([ { "id" => collar.id, "code" => "COL", "name" => collar.name, "use" => "collar" },
                                     { "id" => vaccine.id, "code" => "RAB", "name" => vaccine.name, "use" => "rabies_vaccine" } ])
    expect(body["open_campaign"]).to be_nil
    expect(body["parameters"]).to eq("collar_months" => 6)
    expect(body["limits"]).to eq("name_max" => 60, "coat_max" => 40, "breed_max" => 60, "microchip_digits" => 15,
                                 "registry_number_max" => 20, "adverse_note_min" => 10, "adverse_note_max" => 500)

    campaign = open_campaign!
    get "/zoonoses/domains"
    expect(json_body["open_campaign"]).to eq("id" => campaign.id, "name" => campaign.name, "starts_on" => (today - 5).iso8601,
                                              "ends_on" => (today + 20).iso8601)
  end

  it "traz todas as listas do domains.yml (rótulos e códigos) e a collar_months da versão vigente" do
    ZoonosesParameterVersion.create!(version: 1, values: Zoonoses::Parameters.defaults.merge("collar_months" => 9), created_by_user: coordinator)
    sign_in_as(coordinator)
    get "/zoonoses/domains"
    body = json_body
    expect(labels.keys).to include(*%w[entry_kinds exit_kinds euthanasia_reasons legal_bases removal_reasons elisa_results leish_decisions
                                       modalities demand_states deadline_colors observation_outcomes subtypes])
    labels.each { |list, rows| expect(body[list]).to eq(rows.map { |row| { "code" => row["code"].to_s, "label" => row["label"] } }), list }
    expect(body["parameters"]).to eq("collar_months" => 9)
  end

  it "Zoonoses::Json.domains valida contra $defs/zoonoses_domains do reference-response v1.4.0 (as chaves da referência)" do
    zoonoses_product!(code: "RAB")
    zoonoses_product!(use: "collar", code: "COL")
    schemer = JSONSchemer.schema(JSON.parse(File.binread(contracts.join("reference-response-v1.json")))).ref("#/$defs/zoonoses_domains")
    # Só saem as listas do dashboard (as do domains.yml fora do esquema):
    # o resto é o §11 inteiro, e o additionalProperties: false vale.
    dashboard = labels.keys - reference_keys
    validate = ->(payload) { schemer.validate(payload.except(*dashboard)).map { |error| error.fetch("error") } }

    without = JSON.parse(Zoonoses::Json.domains.to_json)
    expect(validate.call(without)).to eq([])
    expect(without["open_campaign"]).to be_nil

    open_campaign!
    payload = JSON.parse(Zoonoses::Json.domains.to_json)
    expect(validate.call(payload)).to eq([])
    expect(payload["products"].size).to eq(2)
    expect(payload["open_campaign"]).not_to be_nil
    expect(payload.keys).to include(*reference_keys)
    expect(dashboard).not_to be_empty

    stray = payload.merge("stray_key" => 1)
    expect(validate.call(stray)).not_to eq([])
    expect(validate.call(payload.merge("limits" => payload["limits"].merge("x" => 1)))).not_to eq([])
  end

  it "os rótulos do domains.yml são os do domains-v1.json (zoonoses) do contracts v1.4.0, nas listas da referência" do
    zoonoses = JSON.parse(File.binread(contracts.join("domains-v1.json"))).fetch("zoonoses")
    %w[species sexes sizes animal_statuses dpp_results leish_survey_kinds product_uses].each do |list|
      expect(labels[list]).to eq(zoonoses.fetch(list)), list
    end
    expect(Zoonoses::Json.domains[:limits]).to eq(zoonoses.fetch("limits").symbolize_keys)
  end

  it "a equipe, a coordenação e o municipal_admin leem; ACS e agente de endemias da equipe leem; stock_keeper → 403" do
    [ zoonoses_team!, coordinator, zoonoses_admin ].each do |user|
      sign_in_as(user)
      get "/zoonoses/domains"
      expect(response).to have_http_status(:ok)
    end
    team = registry_team!
    [ field_agent!(team: team), field_agent!(cbo: "515140", team: team) ].each do |agent|
      sign_in_as(agent)
      get "/zoonoses/domains"
      expect([ response.status, json_body ]).to eq([ 200, JSON.parse(Zoonoses::Json.domains.to_json) ])
    end
    sign_in_as(staff_with("almox-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/domains"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(coordinator)
    get "/zoonoses/domains?x=1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "gate desligado → 403 feature_disabled (Q10), inclusive para o agente de campo" do
    agent = field_agent!(team: registry_team!)
    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    [ coordinator, agent ].each do |user|
      sign_in_as(user)
      get "/zoonoses/domains"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end
  end
end
