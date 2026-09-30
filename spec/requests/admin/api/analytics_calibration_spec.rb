# spec/requests/admin/api/analytics_calibration_spec.rb
require "rails_helper"

# Contratos §1.3 (calibração): período inteiro, versão × tier × desfecho, com a
# proporção por linha; célula e proporção suprimidas pela mesma regra.
RSpec.describe "GET /admin/api/analytics/calibration", type: :request do
  let(:monday) { (Time.zone.today - 21).beginning_of_week }
  let(:range) { { from: monday.iso8601, to: (monday + 13).iso8601 } }
  let(:hidden) { { "suppressed" => true } }

  def data = JSON.parse(response.body)["data"]

  def outcome!(protocol, version, tier, dim, value, day: monday)
    fact!(metric: "calibration.outcome", day: day, value: value, protocol_name: protocol, protocol_version: version,
          tier: tier, dim: dim)
  end

  before do
    ProtocolDefinition.create!(name: "resp", version: 1, status: "retired", definition: analytics_definition(name: "resp"))
    ProtocolDefinition.create!(name: "resp", version: 2, status: "active", definition: analytics_definition(name: "resp", version: 2))
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "municipal_admin"))
    outcome!("resp", 1, "alta", "discharged", 6)
    outcome!("resp", 1, "alta", "discharged", 4, day: monday + 9) # soma no período
    outcome!("resp", 1, "alta", "referred", 5)
    outcome!("resp", 1, "alta", "none", 5)
    outcome!("resp", 1, "baixa", "discharged", 3)
    outcome!("resp", 2, "alta", "none", 6)
    outcome!("arbo", 1, "media", "left", 8)
  end

  it "versões por nome e versão desc; linhas por total desc; outcomes e shares com as cinco chaves" do
    get "/admin/api/analytics/calibration", params: range

    expect(data).to include("granularity" => nil, "periods" => [])
    expect(data["versions"].map { |v| [ v["protocol_name"], v["protocol_version"] ] })
      .to eq([ [ "arbo", 1 ], [ "resp", 2 ], [ "resp", 1 ] ])
    resp_v1 = data["versions"].last
    expect(resp_v1["rows"]).to eq([
      { "tier" => "alta", "total" => 20,
        "outcomes" => { "discharged" => 10, "referred" => 5, "return" => 0, "left" => 0, "none" => 5 },
        "shares" => { "discharged" => 50.0, "referred" => 25.0, "return" => 0.0, "left" => 0.0, "none" => 25.0 } },
      { "tier" => "baixa", "total" => hidden,
        "outcomes" => { "discharged" => hidden, "referred" => 0, "return" => 0, "left" => 0, "none" => 0 },
        "shares" => { "discharged" => hidden, "referred" => hidden, "return" => hidden, "left" => hidden, "none" => hidden } }
    ])
  end

  it "total do grupo: um desfecho oculto esconde o total e todas as proporções da linha" do
    outcome!("arbo", 1, "media", "discharged", 20)
    outcome!("arbo", 1, "media", "referred", 2)

    get "/admin/api/analytics/calibration", params: range

    expect(data["versions"].find { |v| v["protocol_name"] == "arbo" }["rows"]).to eq([
      { "tier" => "media", "total" => hidden,
        "outcomes" => { "discharged" => 20, "referred" => hidden, "return" => 0, "left" => 8, "none" => 0 },
        "shares" => { "discharged" => hidden, "referred" => hidden, "return" => hidden, "left" => hidden, "none" => hidden } }
    ])
  end

  it "recorta por protocolo e versão" do
    get "/admin/api/analytics/calibration", params: range.merge(protocol_name: "resp", protocol_version: "2")

    expect(data["filter"]).to include("protocol_name" => "resp", "protocol_version" => 2)
    expect(data["versions"]).to eq([ { "protocol_name" => "resp", "protocol_version" => 2, "rows" => [
      { "tier" => "alta", "total" => 6,
        "outcomes" => { "discharged" => 0, "referred" => 0, "return" => 0, "left" => 0, "none" => 6 },
        "shares" => { "discharged" => 0.0, "referred" => 0.0, "return" => 0.0, "left" => 0.0, "none" => 100.0 } }
    ] } ])
  end
end
