require "rails_helper"

# Contrato §9: simulador do editor para a variante screening. Usa a definição
# em edição (não a ativa), nunca grava, sempre 200 com errors.
RSpec.describe "Simulador do protocolo de acolhimento", type: :request do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def body = JSON.parse(response.body)
  def simulate(params) = post("/authoring/protocols/simulate_screening", params: params, as: :json)
  def definition(rules = ScreeningHelpers::RULES)
    { "name" => "acolhimento", "version" => 3, "kind" => "screening", "risk_rules" => rules }
  end

  it "autor e revisor simulam a definição em edição; os demais 403 missing_role" do
    sign_in_as(staff_with("autor-sim@cidade.gov.br", "protocol_author"))
    simulate(definition: definition, vitals: { systolic: 120, diastolic: 80, temperature_c: "39,2" }, ciap2_code: "R05",
             profile: { age: 30, sex: "male" })
    expect(body).to eq("suggested_color" => "yellow",
                       "matched_rules" => [ { "index" => 1, "text" => "temperatura ≥ 39 ou glicemia ≥ 300" },
                                            { "index" => 2, "text" => "queixa (CIAP-2) = R05" } ],
                       "errors" => [], "warnings" => [])
    expect(ProtocolDefinition.count).to eq(0)
    sign_in_as(staff_with("admin-sim@cidade.gov.br", "municipal_admin"))
    simulate(definition: definition, vitals: {})
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
  end

  it "definição inválida, de triagem ou sinais implausíveis: 200 com errors e sem cor" do
    sign_in_as(staff_with("revisora-sim@cidade.gov.br", "protocol_reviewer"))
    simulate(definition: definition([ { "when" => { "gte" => ["outcome.score", 1] }, "color" => "red" } ]), vitals: {})
    expect(response).to have_http_status(:ok)
    expect(body["suggested_color"]).to be_nil
    expect(body["errors"].join).to include("risk_rules[0].when")
    simulate(definition: { "name" => "t", "version" => 1 }, vitals: {})
    expect(body["errors"]).to include("definition is not a screening protocol")
    simulate(definition: definition, vitals: { spo2: 20 })
    expect(body["errors"]).to eq([ "vitals: implausible_vital spo2" ])
    simulate(definition: "x", vitals: {})
    expect(body["errors"]).to eq([ Protocols::SimulateOffer::NOT_AN_OBJECT ])
  end
end
