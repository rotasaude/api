require "rails_helper"

# Contrato §8: catálogo-base, só plataforma; versão nova a cada gravação.
RSpec.describe "Maintenance: catálogo-base das linhas de cuidado", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "linhas-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, variables = {}) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  CARE_LINE_UPSERT = <<~GQL.freeze
    mutation Upsert($key: String!, $name: String!, $indicator: String!, $declaredCondition: String, $eligibility: JSON!, $practices: JSON!) {
      upsertCareLineTemplate(key: $key, name: $name, indicator: $indicator, declaredCondition: $declaredCondition,
                             eligibility: $eligibility, practices: $practices) { ok errors { path message } }
    }
  GQL
  CARE_LINE_LIST = "query { careLineTemplates(key: \"diabetes_c4\") { key version current name indicator declaredCondition practices createdBy } }".freeze

  before do
    CareLines::Templates::Load.call
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now }, headers: browser
  end

  def diabetes_vars(**over)
    t = CareLineTemplate.current("diabetes_c4")
    { key: t.key, name: t.name, indicator: t.indicator, declaredCondition: t.declared_condition, eligibility: t.eligibility,
      practices: t.practices }.merge(over)
  end

  it "lista as versões; upsert grava a versão 2 e audita sem abrir cidade" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!(CARE_LINE_UPSERT, diabetes_vars(name: "Pessoa com diabetes (nota 2027)"))
    expect(json.dig("data", "upsertCareLineTemplate")).to eq("ok" => true, "errors" => [])
    gql!(CARE_LINE_LIST)
    rows = json.dig("data", "careLineTemplates")
    expect(rows.map { |r| [ r["version"], r["current"], r["name"] ] })
      .to eq([ [ 2, true, "Pessoa com diabetes (nota 2027)" ], [ 1, false, "Pessoa com diabetes" ] ])
    expect(rows.map { |r| [ r["version"], r["createdBy"] ] }).to eq([ [ 2, maintainer.email_address ], [ 1, nil ] ])
    expect(rows.first["practices"].first["key"]).to eq("c4_a")
    audit = PlatformEvent.where(name: "maintenance.care_line_template.changed").order(:created_at).pluck(:payload)
    expect(audit.map { |p| p["outcome"] }).to eq(%w[attempted ok])
    expect(audit.last.keys).not_to include("name")
  end

  it "recusa com path e não grava" do
    bad = diabetes_vars(practices: CareLineTemplate.current("diabetes_c4").practices.map { |p| p.merge("window_days" => 0) })
    gql!(CARE_LINE_UPSERT, bad)
    expect(json.dig("data", "upsertCareLineTemplate")).to eq("ok" => false,
                                                             "errors" => [ { "path" => "practices[0].window_days", "message" => "invalid_practices" } ])
    gql!(CARE_LINE_UPSERT, diabetes_vars(indicator: "C5"))
    expect(json.dig("data", "upsertCareLineTemplate", "errors")).to eq([ { "path" => "indicator", "message" => "invalid_indicator" } ])
    expect(CareLineTemplate.where(key: "diabetes_c4").count).to eq(1)
  end

  it "recusa declaredCondition fora de eligibility.declared com path declaredCondition e não grava" do
    t = CareLineTemplate.current("diabetes_c4")
    gql!(CARE_LINE_UPSERT, diabetes_vars(eligibility: t.eligibility.merge("declared" => [ "hypertension" ])))
    expect(json.dig("data", "upsertCareLineTemplate"))
      .to eq("ok" => false, "errors" => [ { "path" => "declaredCondition", "message" => "invalid_declared_condition" } ])
    expect(CareLineTemplate.where(key: "diabetes_c4").count).to eq(1)
  end

  it "a ida e volta da C2 (sem problems, listas vazias) grava a versão 2 sem step-up e devolve os avançados iguais" do
    t = CareLineTemplate.current("child_c2")
    vars = { key: t.key, name: t.name, indicator: t.indicator, declaredCondition: nil,
             eligibility: { "problems" => { "ciap2" => [], "cid10" => [] }, "age_max_days" => 730, "requires_anchor" => nil },
             practices: t.practices }
    gql!(CARE_LINE_UPSERT, vars)
    expect(json.dig("data", "upsertCareLineTemplate")).to eq("ok" => true, "errors" => [])
    saved = CareLineTemplate.current("child_c2")
    expect([ saved.version, saved.eligibility, saved.practices ]).to eq([ 2, { "age_max_days" => 730 }, t.practices ])
  end

  it "token de serviço não alcança os dois campos (HumanOnly)" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write", city_slugs: [], expires_at: 10.days.from_now)
    t = CareLineTemplate.current("diabetes_c4")
    upsert = "mutation { upsertCareLineTemplate(key: \"diabetes_c4\", name: \"x\", indicator: \"#{t.indicator}\", " \
             "eligibility: {}, practices: []) { ok } }"
    [ CARE_LINE_LIST, upsert ].each do |query|
      post "/graphql", params: { query: query, variables: "{}" }, headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
      expect(json["errors"]).to be_present
    end
    expect(CareLineTemplate.where(key: "diabetes_c4").count).to eq(1)
  end
end
