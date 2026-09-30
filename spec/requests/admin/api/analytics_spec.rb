# spec/requests/admin/api/analytics_spec.rb
require "rails_helper"

# ADR 0025 (D6, D12) e contratos §0/§1: quem lê, o envelope, os parâmetros e
# a soma antes da supressão. O conteúdo de cada frente tem spec própria.
RSpec.describe "Admin::Api analytics: acesso, envelope e parâmetros", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:today) { Time.zone.today }
  let(:monday) { (today - 14).beginning_of_week }
  let(:range) { { from: monday.iso8601, to: (monday + 6).iso8601 } }
  let(:hidden) { { "suppressed" => true } }

  def json = JSON.parse(response.body)
  def analyst = staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst")

  it "analyst e municipal_admin leem; todo outro papel recebe 403 forbidden_role" do
    consolidated_run!
    %w[analyst municipal_admin].each do |role|
      sign_in_as(staff_with("ok-#{role}-#{SecureRandom.hex(2)}@cidade.gov.br", role))
      get "/admin/api/analytics/demand", params: range
      expect(response).to have_http_status(:ok), role
    end
    (Membership::ROLES - %w[analyst municipal_admin]).each do |role|
      sign_in_as(staff_with("no-#{role}-#{SecureRandom.hex(2)}@cidade.gov.br", role))
      get "/admin/api/analytics/demand", params: range
      expect(response).to have_http_status(:forbidden), role
      expect(json).to eq("error" => "forbidden_role")
    end
  end

  it "operador com grant recebe 403 forbidden_role — e segue lendo o resto de /admin/api" do
    operator = Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                                otp_secret: ROTP::Base32.random, otp_enabled: true)
    sign_in_operator_grant(operator)

    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "forbidden_role")

    get "/admin/api/overview", params: { period: "7d" }
    expect(response).to have_http_status(:ok)
  end

  it "sem sessão: 401; sem vínculo ativo: 403 no_city_membership; frente desconhecida: 404" do
    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(User.create!(email_address: "sem-vinculo-#{SecureRandom.hex(3)}@x.com", password: "senha-segura-123"))
    get "/admin/api/analytics/demand", params: range
    expect(json).to eq("error" => "no_city_membership")

    sign_in_as(analyst)
    get "/admin/api/analytics/lixo", params: range
    expect(response).to have_http_status(:not_found)
  end

  it "nunca consolidado: as_of nulo, stale, períodos e séries vazios" do
    sign_in_as(analyst)
    get "/admin/api/analytics/demand", params: range

    expect(json).to include("as_of" => nil, "stale" => true)
    expect(json["data"]).to include("front" => "demand", "granularity" => "week", "periods" => [],
                                    "from" => monday.iso8601, "to" => (monday + 6).iso8601)
    expect(json.dig("data", "triages")).to eq("started" => [], "completed" => [], "aborted" => [])
  end

  it "as_of é o fim do último run succeeded, em UTC; stale depois de 36 h" do
    run = consolidated_run!(finished_at: 2.hours.ago)
    sign_in_as(analyst)

    get "/admin/api/analytics/demand", params: range
    expect(json).to include("as_of" => run.finished_at.utc.iso8601, "stale" => false)

    run.update!(finished_at: 37.hours.ago)
    get "/admin/api/analytics/demand", params: range
    expect(json["stale"]).to be(true)
  end

  it "parâmetros inválidos: 422 com o código do contrato; to depois de ontem é truncado" do
    consolidated_run!
    sign_in_as(analyst)
    {
      {} => "invalid_range",
      range.merge(to: (monday - 1).iso8601) => "invalid_range",
      range.merge(granularity: "day") => "invalid_range",
      range.merge(from: (monday - 7 * 110).iso8601) => "invalid_range",
      range.merge(neighborhood_id: SecureRandom.uuid) => "invalid_neighborhood",
      range.merge(health_unit_id: "nao-e-uuid") => "invalid_unit",
      range.merge(protocol_name: "nao-existe") => "invalid_protocol"
    }.each do |params, error|
      get "/admin/api/analytics/demand", params: params
      expect(response).to have_http_status(:unprocessable_entity), params.inspect
      expect(json).to eq("error" => error), params.inspect
    end

    get "/admin/api/analytics/demand", params: range.merge(to: (today + 10).iso8601)
    expect(json.dig("data", "to")).to eq((today - 1).iso8601)
  end

  it "soma antes de suprimir: dois dias com 3 na semana mostram 6; um dia com 3 fica oculto; o mesmo por mês" do
    consolidated_run!
    sign_in_as(analyst)
    fact!(metric: "triage.started", day: monday, value: 3, protocol_name: "resp", protocol_version: 1)
    fact!(metric: "triage.started", day: monday + 1, value: 3, protocol_name: "resp", protocol_version: 1)
    fact!(metric: "triage.started", day: monday + 7, value: 3, protocol_name: "resp", protocol_version: 1)

    get "/admin/api/analytics/demand", params: { from: monday.iso8601, to: (monday + 13).iso8601 }
    expect(json.dig("data", "triages", "started")).to eq([ 6, hidden ])
    # Total do grupo (contratos §0): 9 ao lado do 3 oculto o devolveria por subtração.
    expect(json.dig("data", "triages_total", "started")).to eq(hidden)

    month = (today << 3).beginning_of_month
    fact!(metric: "triage.completed", day: month + 1, value: 3, tier: "alta", protocol_name: "resp", protocol_version: 1)
    fact!(metric: "triage.completed", day: month + 20, value: 3, tier: "alta", protocol_name: "resp", protocol_version: 1)
    get "/admin/api/analytics/demand", params: { from: month.iso8601, to: (month + 27).iso8601, granularity: "month" }
    expect(json.dig("data", "triages", "completed")).to eq([ 6 ])
    expect(json.dig("data", "triages_total", "completed")).to eq(6)
    get "/admin/api/analytics/demand", params: { from: month.iso8601, to: (month + 27).iso8601 }
    expect(json.dig("data", "triages", "completed")).to all(eq(0).or(eq(hidden)))
  end

  it "vínculo de analyst revogado: 403 forbidden_role (com outro vínculo ativo) ou no_city_membership (sem nenhum)" do
    consolidated_run!
    with_viewer = staff_with("revogado-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst", "viewer")
    with_viewer.memberships.find_by!(role: "analyst").revoke!
    sign_in_as(with_viewer)
    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "forbidden_role")

    only_analyst = analyst
    only_analyst.memberships.each(&:revoke!)
    sign_in_as(only_analyst)
    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "no_city_membership")
  end

  # Status::STALE_AFTER com `<`: exatamente 36 h ainda não é velho.
  it "stale na borda: 36 h exatas é fresco; 36 h + 1 s é velho" do
    freeze_time do
      run = consolidated_run!(finished_at: Time.current - 36.hours)
      sign_in_as(analyst)

      get "/admin/api/analytics/demand", params: range
      expect(json["stale"]).to be(false)

      run.update!(finished_at: Time.current - 36.hours - 1.second)
      get "/admin/api/analytics/demand", params: range
      expect(json["stale"]).to be(true)
    end
  end

  it "422 por HTTP: versão sem protocolo, unidade inexistente, 61 meses, parâmetro em array" do
    consolidated_run!
    sign_in_as(analyst)
    ProtocolDefinition.create!(name: "resp", version: 1, status: "active", definition: analytics_definition(name: "resp"))
    month = (today << 3).beginning_of_month
    {
      [ "epidemiology", range.merge(protocol_version: "1") ] => "invalid_protocol",
      [ "calibration", range.merge(protocol_version: "1") ] => "invalid_protocol",
      [ "quality", range.merge(health_unit_id: SecureRandom.uuid) ] => "invalid_unit",
      [ "demand", { from: (month << 60).iso8601, to: month.iso8601, granularity: "month" } ] => "invalid_range",
      [ "demand", range.merge(neighborhood_id: [ SecureRandom.uuid ]) ] => "invalid_neighborhood",
      [ "demand", range.merge(health_unit_id: [ SecureRandom.uuid ]) ] => "invalid_unit",
      [ "demand", range.merge(protocol_name: [ "resp" ]) ] => "invalid_protocol",
      [ "epidemiology", range.merge(protocol_name: "resp", protocol_version: [ "1" ]) ] => "invalid_protocol"
    }.each do |(front, params), error|
      get "/admin/api/analytics/#{front}", params: params
      expect(response).to have_http_status(:unprocessable_entity), "#{front} #{params.inspect}"
      expect(json).to eq("error" => error), "#{front} #{params.inspect}"
    end

    # 60 meses é a borda aceita.
    get "/admin/api/analytics/demand", params: { from: (month << 59).iso8601, to: month.iso8601, granularity: "month" }
    expect(response).to have_http_status(:ok)
  end

  # O analyst não lê /attendance/units, mas precisa dos seletores de bairro e
  # protocolo (contratos §1): as duas leituras de /admin/api que o dashboard usa.
  it "analyst lê /admin/api/neighborhoods e /admin/api/protocols" do
    sign_in_as(analyst)

    get "/admin/api/neighborhoods"
    expect(response).to have_http_status(:ok)
    get "/admin/api/protocols"
    expect(response).to have_http_status(:ok)
  end
end
