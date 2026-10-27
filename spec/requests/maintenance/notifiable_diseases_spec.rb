require "rails_helper"

# Módulo 25 (ADR 0043): a lista nacional de notificação compulsória, na
# plataforma. Listar é leitura; publicar exige o TOTP do momento (step-up) e é
# auditado sem abrir cidade.
RSpec.describe "Maintenance: lista nacional de notificação compulsória", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "doencas-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def totp = ROTP::TOTP.new(maintainer.otp_secret).now
  def gql!(query, variables = {}) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)
  def payload = json.dig("data", "publishNotifiableDiseaseList")

  PUBLISH_LIST = <<~GQL.freeze
    mutation Publish($ordinance: String!, $effectiveFrom: ISO8601Date!, $expectedVersion: Int, $diseases: [NotifiableDiseaseInput!]!, $notes: String, $code: String!) {
      publishNotifiableDiseaseList(ordinance: $ordinance, effectiveFrom: $effectiveFrom, expectedVersion: $expectedVersion,
                                   diseases: $diseases, notes: $notes, code: $code) { ok errors { path message } version }
    }
  GQL
  LIST_VERSIONS = <<~GQL.freeze
    query { notifiableDiseases {
      version ordinance effectiveFrom current notes sources createdAt publishedBy
      diseases { code name deadline cid10 ciap2 repeatAfterDays sinanForm notes sources }
    } }
  GQL

  before do
    Surveillance::DiseaseList::Load.call
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    # O código do login é consumido: o login acontece um minuto atrás para que
    # o step-up tenha um passo de TOTP novo.
    travel_to(1.minute.ago) do
      post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
      post "/session/challenge", params: { session_id: json["session_id"], code: totp }, headers: browser
    end
  end

  def dengue_input(**over)
    d = NotifiableDisease.find_by!(code: "dengue")
    { code: d.code, name: d.name, deadline: d.deadline, cid10: d.cid10, ciap2: d.ciap2, repeatAfterDays: d.repeat_after_days,
      sinanForm: d.sinan_form, notes: d.notes, sources: d.sources }.merge(over)
  end

  def vars(diseases: [ dengue_input ], **over)
    { ordinance: "Portaria GM/MS nº 99/2027", effectiveFrom: (Time.zone.today + 30).iso8601, expectedVersion: 1,
      diseases: diseases, notes: "revisão trimestral", code: totp }.merge(over)
  end

  it "lista a versão 1 da carga como vigente, com a dengue" do
    gql!(LIST_VERSIONS)
    rows = json.dig("data", "notifiableDiseases")
    expect(rows.map { |r| [ r["version"], r["current"], r["publishedBy"] ] }).to eq([ [ 1, true, nil ] ])
    dengue = rows.first["diseases"].find { |d| d["code"] == "dengue" }
    expect(dengue).to include("cid10" => [ "A90" ], "deadline" => "weekly")
    expect(dengue["sources"]).to be_a(Hash).and be_present
    expect(rows.first["sources"]).to include("ordinance")
  end

  it "publica a versão 2 com TOTP válido, audita e não abre cidade" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!(PUBLISH_LIST, vars(diseases: [ dengue_input(name: "Dengue (revisada)") ]))
    expect(payload).to eq("ok" => true, "errors" => [], "version" => 2)

    gql!(LIST_VERSIONS)
    rows = json.dig("data", "notifiableDiseases")
    expect(rows.map { |r| [ r["version"], r["current"] ] }).to eq([ [ 2, false ], [ 1, true ] ]) # a nova é agendada
    expect(rows.first).to include("publishedBy" => maintainer.email_address, "ordinance" => "Portaria GM/MS nº 99/2027", "notes" => "revisão trimestral")
    expect(rows.first["diseases"].map { |d| d["name"] }).to eq([ "Dengue (revisada)" ])

    audit = PlatformEvent.where(name: "maintenance.notifiable_disease_list.published").order(:created_at).pluck(:payload)
    expect(audit.map { |p| p["outcome"] }).to eq(%w[attempted ok])
    expect(audit.last).to include("module" => "surveillance", "diseases_count" => 1)
    expect(audit.last.keys).not_to include("name", "email", "ordinance")
    expect(PlatformEvent.where(name: "notifiable_disease_list.published").count).to eq(1)
  end

  it "recusa TOTP errado e não grava versão" do
    gql!(PUBLISH_LIST, vars(code: "000000"))
    expect(payload).to include("ok" => false, "version" => nil)
    expect(payload["errors"].first).to include("path" => "code")
    expect(NotifiableDiseaseVersion.count).to eq(1)
    expect(PlatformEvent.where(name: "maintenance.notifiable_disease_list.published").last.payload["outcome"]).to eq("rejected")
  end

  it "recusa lista inválida com o path da doença em camelCase" do
    gql!(PUBLISH_LIST, vars(diseases: [ dengue_input(deadline: "monthly") ]))
    expect(payload).to include("ok" => false, "version" => nil)
    expect(payload["errors"].first).to include("path" => "diseases.0.deadline")
    expect(NotifiableDiseaseVersion.count).to eq(1)

    travel 31.seconds do
      gql!(PUBLISH_LIST, vars(diseases: [ dengue_input, dengue_input(code: "outra", name: "Outra", cid10: [ "B01" ], repeatAfterDays: 0) ]))
      expect(payload["errors"].first).to include("path" => "diseases.1.repeatAfterDays")
    end
    travel 62.seconds do
      gql!(PUBLISH_LIST, vars(diseases: [ dengue_input(cid10: [ "A90", "xx" ]) ]))
      expect(payload["errors"].first).to include("path" => "diseases.0.cid10.1")
    end
    travel 93.seconds do
      gql!(PUBLISH_LIST, vars(diseases: [ dengue_input(sinanForm: "") ]))
      expect(payload["errors"].first).to include("path" => "diseases.0.sinanForm")
    end
    travel 124.seconds do
      gql!(PUBLISH_LIST, vars(diseases: [ dengue_input(sources: {}) ]))
      expect(payload["errors"].first).to include("path" => "diseases.0.sources")
    end
  end

  it "recusa a versão de partida desatualizada, sem gravar versão nova" do
    gql!(PUBLISH_LIST, vars(expectedVersion: 0))
    expect(payload).to include("ok" => false, "version" => nil)
    expect(payload["errors"].map { |e| e["path"] }).to eq([ "expectedVersion" ])
    expect(NotifiableDiseaseVersion.count).to eq(1)
  end

  it "recusa a versão de partida ausente" do
    gql!(PUBLISH_LIST, vars(expectedVersion: nil))
    expect(payload).to include("ok" => false, "version" => nil)
    expect(payload["errors"].map { |e| e["path"] }).to eq([ "expectedVersion" ])
    expect(NotifiableDiseaseVersion.count).to eq(1)
  end

  it "recusa vigência no passado" do
    gql!(PUBLISH_LIST, vars(effectiveFrom: (Time.zone.today - 1).iso8601))
    expect(payload).to include("ok" => false, "version" => nil)
    expect(payload["errors"].map { |e| e["path"] }).to eq([ "effectiveFrom" ])
    expect(NotifiableDiseaseVersion.count).to eq(1)
  end

  it "token de serviço não alcança a consulta nem a publicação (HumanOnly)" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write", city_slugs: [], expires_at: 10.days.from_now)
    publish = "mutation { publishNotifiableDiseaseList(ordinance: \"x\", effectiveFrom: \"#{Time.zone.today + 30}\", expectedVersion: 1, " \
              "diseases: [], code: \"000000\") { ok } }"
    [ LIST_VERSIONS, publish ].each do |query|
      post "/graphql", params: { query: query, variables: "{}" }, headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
      expect(json["errors"]).to be_present
    end
    expect(NotifiableDiseaseVersion.count).to eq(1)
  end
end
