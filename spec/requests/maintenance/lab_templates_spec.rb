require "rails_helper"

# Contrato §10 com M1 (SDL), M3 (erros), M4 (sem step-up), M7 (sem exclusão).
RSpec.describe "Maintenance: catálogo-base do laboratório", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "lab-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, variables = {}) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  LAB_EXAM = <<~GQL.freeze
    mutation UpsertLabExamTemplate($id: ID, $sigtapCode: String!, $name: String!, $sector: String!, $material: String!, $container: String!, $active: Boolean!) {
      upsertLabExamTemplate(id: $id, sigtapCode: $sigtapCode, name: $name, sector: $sector, material: $material, container: $container,
                            suggestedMethod: "Enzimático", preparation: null, active: $active) { ok errors { path message } }
    }
  GQL
  LAB_ANALYTE = <<~GQL.freeze
    mutation UpsertLabAnalyteTemplate($templateId: ID!, $key: String!, $ranges: [LabReferenceRangeInput!]!) {
      upsertLabAnalyteTemplate(labExamTemplateId: $templateId, key: $key, name: "Glicose", loinc: "2345-7", unit: "mg/dL",
                               valueType: "numeric", decimals: 0, position: 1, referenceRanges: $ranges) { ok errors { path message } }
    }
  GQL
  LAB_LIST = "query LabExamTemplates { labExamTemplates { id sigtapCode name sector active analytes { key valueType choices referenceRanges { sex ageMinDays ageMaxDays low high text } } } }".freeze

  before do
    sigtap_release!
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now }, headers: browser
  end

  # D6: texto além do limite é recusado, nunca cortado em silêncio.
  it "recusa nome longo demais do exame (invalid_name) e unidade longa do componente (invalid_unit), sem gravar" do
    vars = { sigtapCode: "0202010473", name: "G" * 121, sector: "biochemistry", material: "Plasma", container: "Tubo cinza", active: true }
    gql!(LAB_EXAM, vars)
    expect(json.dig("data", "upsertLabExamTemplate")).to eq("ok" => false, "errors" => [ { "path" => "name", "message" => "invalid_name" } ])
    expect(LabExamTemplate.where(sigtap_code: "0202010473")).not_to exist
    gql!(LAB_EXAM, vars.merge(name: "G" * 120))
    expect(LabExamTemplate.find_by!(sigtap_code: "0202010473").name.length).to eq(120)
    template = LabExamTemplate.find_by!(sigtap_code: "0202010473")
    long_unit = LAB_ANALYTE.sub('unit: "mg/dL"', %(unit: "#{'u' * 31}"))
    gql!(long_unit, templateId: template.id, key: "glicose", ranges: [])
    expect(json.dig("data", "upsertLabAnalyteTemplate", "errors")).to eq([ { "path" => "unit", "message" => "invalid_unit" } ])
    expect(template.analytes.count).to eq(0)
  end

  it "cria exame e componente, lista com faixas, recusa com path, desativa; audita sem abrir cidade" do
    expect(Maintenance::CityReader).not_to receive(:call)
    vars = { sigtapCode: "0202010473", name: "Glicose", sector: "biochemistry", material: "Plasma", container: "Tubo cinza", active: true }
    gql!(LAB_EXAM, vars)
    expect(json.dig("data", "upsertLabExamTemplate")).to eq("ok" => true, "errors" => [])
    template = LabExamTemplate.find_by!(sigtap_code: "0202010473")
    ranges = [ { sex: "any", ageMinDays: 0, ageMaxDays: 43_800, low: 70.0, high: 99.0, text: nil } ]
    gql!(LAB_ANALYTE, templateId: template.id, key: "glicose", ranges: ranges)
    expect(json.dig("data", "upsertLabAnalyteTemplate", "ok")).to be(true)
    gql!(LAB_EXAM, vars.merge(sector: "hormones"))
    expect(json.dig("data", "upsertLabExamTemplate")).to eq("ok" => false, "errors" => [ { "path" => "sector", "message" => "invalid_sector" } ])
    gql!(LAB_ANALYTE, templateId: template.id, key: "Bad Key", ranges: ranges)
    expect(json.dig("data", "upsertLabAnalyteTemplate", "errors")).to eq([ { "path" => "key", "message" => "invalid_analyte_key" } ])
    gql!(LAB_EXAM, vars.merge(id: template.id, active: false))
    gql!(LAB_LIST)
    expect(json.dig("data", "labExamTemplates")).to eq([ {
      "id" => template.id, "sigtapCode" => "0202010473", "name" => "Glicose", "sector" => "biochemistry", "active" => false,
      "analytes" => [ { "key" => "glicose", "valueType" => "numeric", "choices" => [],
                        "referenceRanges" => [ { "sex" => "any", "ageMinDays" => 0, "ageMaxDays" => 43_800, "low" => 70.0, "high" => 99.0, "text" => nil } ] } ] } ])
    outcomes = PlatformEvent.where(name: "maintenance.lab_template.changed").pluck(Arel.sql("payload->>'outcome'"))
    expect(outcomes).to include("attempted", "ok", "rejected")
  end

  it "token de serviço não alcança os três campos" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write", city_slugs: [], expires_at: 10.days.from_now)
    [ LAB_LIST, "mutation { upsertLabExamTemplate(sigtapCode: \"0202010473\", name: \"x\", sector: \"biochemistry\", material: \"x\", container: \"x\", active: true) { ok } }" ].each do |query|
      post "/graphql", params: { query: query, variables: "{}" }, headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
      expect(json["errors"]).to be_present
    end
    expect(LabExamTemplate.count).to eq(0)
  end

  # Divergência M1 do plano do maintenance (o consumidor): o BLOCO inteiro, não três linhas.
  LAB_M1_SDL = <<~GQL.freeze
    type LabExamTemplate {
      active: Boolean!
      analytes: [LabAnalyteTemplate!]!
      container: String!
      id: ID!
      material: String!
      name: String!
      preparation: String
      sector: String!
      sigtapCode: String!
      suggestedMethod: String
    }
    type LabAnalyteTemplate {
      choices: [String!]!
      decimals: Int!
      id: ID!
      key: String!
      loinc: String
      name: String!
      position: Int!
      referenceRanges: [LabReferenceRange!]!
      unit: String
      valueType: String!
    }
    type LabReferenceRange { ageMaxDays: Int! ageMinDays: Int! high: Float low: Float sex: String! text: String }
    input LabReferenceRangeInput { ageMaxDays: Int! ageMinDays: Int! high: Float low: Float sex: String! text: String }
    type UpsertLabExamTemplatePayload { errors: [UserError!]! ok: Boolean! }
    type UpsertLabAnalyteTemplatePayload { errors: [UserError!]! ok: Boolean! }
    type Query {
      labExamTemplates: [LabExamTemplate!]!
    }
    type Mutation {
      upsertLabExamTemplate(active: Boolean!, container: String!, id: ID, material: String!, name: String!, preparation: String, sector: String!, sigtapCode: String!, suggestedMethod: String): UpsertLabExamTemplatePayload
      upsertLabAnalyteTemplate(choices: [String!] = [], decimals: Int!, id: ID, key: String!, labExamTemplateId: ID!, loinc: String, name: String!, position: Int!, referenceRanges: [LabReferenceRangeInput!]!, unit: String, valueType: String!): UpsertLabAnalyteTemplatePayload
    }
  GQL

  # Assinatura sem descrições: "campo(arg: Tipo = padrão): Tipo", ordenada.
  def signature(definition)
    printer = GraphQL::Language::Printer.new
    arg = lambda do |a|
      text = "#{a.name}: #{printer.print(a.type)}"
      a.default_value.nil? ? text : "#{text} = #{printer.print(a.default_value)}"
    end
    members = (definition.respond_to?(:fields) ? definition.fields : definition.arguments).map do |f|
      args = f.respond_to?(:arguments) && f.arguments.any? ? "(#{f.arguments.map(&arg).sort.join(", ")})" : ""
      type = f.respond_to?(:type) ? ": #{printer.print(f.type)}" : ""
      "#{f.name}#{args}#{type}"
    end
    "#{definition.class.name.split("::").last} #{definition.name} { #{members.sort.join("; ")} }"
  end

  it "o SDL é o bloco inteiro da Divergência M1" do
    ours = GraphQL.parse(Maintenance::Schema.to_definition).definitions.index_by(&:name)
    wanted = GraphQL.parse(LAB_M1_SDL).definitions
    wanted.each do |expected|
      actual = ours.fetch(expected.name)
      if %w[Query Mutation].include?(expected.name)
        expected.fields.each do |field|
          mine = actual.fields.find { |f| f.name == field.name }
          expect(mine).not_to be_nil, "#{expected.name}.#{field.name} ausente"
          expect(signature(actual.merge(fields: [ mine ]))).to eq(signature(expected.merge(fields: [ field ])))
        end
      else
        expect(signature(actual)).to eq(signature(expected))
      end
    end
  end
end
