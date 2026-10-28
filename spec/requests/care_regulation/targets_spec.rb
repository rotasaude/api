require "rails_helper"

# Módulo 26a (ADR 0044; contrato §13 G3): GET /regulation/targets.
RSpec.describe "Regulação — alvos", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { regulation_city! }
  let(:unit) { create_unit("UBS Alvos") }
  let(:doctor) { doctor!(unit) }

  it "o profissional lista as especialidades por nome, com nurse_allowed" do
    CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225250", by: regulation_admin!)
    sign_in_as(doctor)
    get "/regulation/targets", params: { type: "specialty" }
    expect(response).to have_http_status(:ok)
    targets = json_body.fetch("targets")
    expect(targets.size).to eq(CareRegulation::Targets.specialties.size)
    expect(targets.first.keys).to eq(%w[type code name group nurse_allowed])
    expect(targets.map { |t| t["name"] }).to eq(targets.map { |t| t["name"] }.sort_by { |n| I18n.transliterate(n).downcase })
    cardio = targets.find { |t| t["code"] == "225120" }
    expect(cardio).to eq("type" => "specialty", "code" => "225120", "name" => "Cardiologia", "group" => "medical", "nurse_allowed" => false)
    expect(targets.find { |t| t["code"] == "225250" }["nurse_allowed"]).to be(true)
    expect(targets.find { |t| t["code"] == "223212" }).to include("name" => "Endodontia", "group" => "dental")
  end

  it "q filtra a especialidade; limit corta" do
    sign_in_as(doctor)
    get "/regulation/targets", params: { type: "specialty", q: "cardio" }
    expect(json_body["targets"].map { |t| t["code"] }).to include("225120")
    expect(json_body["targets"].size).to be < 5
    get "/regulation/targets", params: { type: "specialty", limit: "3" }
    expect(json_body["targets"].size).to eq(3)
  end

  it "procedimento: busca por nome, só regulável, com o nome da SIGTAP" do
    sign_in_as(doctor)
    get "/regulation/targets", params: { type: "procedure", q: "esofago" }
    expect(response).to have_http_status(:ok)
    expect(json_body["targets"]).to eq([ { "type" => "procedure", "code" => "0209010037", "name" => "ESOFAGOGASTRODUODENOSCOPIA",
                                           "group" => "procedure", "nurse_allowed" => false } ])
    get "/regulation/targets", params: { type: "procedure", q: "hemodialise" }
    expect(json_body["targets"]).to eq([])
  end

  it "procedimento com q de 2 letras ou sem q → 422 invalid_query" do
    sign_in_as(doctor)
    get "/regulation/targets", params: { type: "procedure", q: "es" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_query" } ])
    get "/regulation/targets", params: { type: "procedure" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_query" } ])
    get "/regulation/targets", params: { type: "procedure", q: "  e " }
    expect(json_body).to eq("error" => "invalid_query")
  end

  it "tipo ausente ou desconhecido → 422 invalid_request (path type); limit ruim → 422 invalid_limit" do
    sign_in_as(doctor)
    get "/regulation/targets"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "type" } ])
    get "/regulation/targets", params: { type: "exam" }
    expect(json_body).to eq("error" => "invalid_request", "path" => "type")
    %w[0 101 abc -1].each do |limit|
      get "/regulation/targets", params: { type: "specialty", limit: limit }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
    end
    get "/regulation/targets", params: { type: "specialty", q: [ "a" ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "q" } ])
  end

  it "procedimento: 20 por padrão e no máximo; de 21 a 100 → 422 invalid_limit; a especialidade segue até 100" do
    travel_to(Time.zone.local(2099, 1, 15, 12)) do
      regulation_bulk_sigtap!("209901", count: 25)
      sign_in_as(doctor)
      get "/regulation/targets", params: { type: "procedure", q: "regulavel de teste" }
      expect(response).to have_http_status(:ok)
      expect(json_body["targets"].size).to eq(20)
      get "/regulation/targets", params: { type: "procedure", q: "regulavel de teste", limit: "20" }
      expect(json_body["targets"].size).to eq(20)
      get "/regulation/targets", params: { type: "procedure", q: "regulavel de teste", limit: "4" }
      expect(json_body["targets"].size).to eq(4)
      %w[21 100].each do |limit|
        get "/regulation/targets", params: { type: "procedure", q: "regulavel de teste", limit: limit }
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
      end
      get "/regulation/targets", params: { type: "specialty", limit: "100" }
      expect(response).to have_http_status(:ok)
    end
  end

  it "regulador e administrador também leem" do
    [ care_regulator!, regulation_admin! ].each do |user|
      sign_in_as(user)
      get "/regulation/targets", params: { type: "specialty", q: "cardio" }
      expect(response).to have_http_status(:ok)
    end
  end

  it "papel sem acesso → 403 missing_role; sem sessão → 401" do
    get "/regulation/targets", params: { type: "specialty" }
    expect(response).to have_http_status(:unauthorized)
    sign_in_as(staff_with("viewer-#{SecureRandom.hex(2)}@cidade.gov.br", "viewer"))
    get "/regulation/targets", params: { type: "specialty" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(doctor)
    get "/regulation/targets", params: { type: "specialty" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
  end
end
