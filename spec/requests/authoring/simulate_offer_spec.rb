require "rails_helper"

# Contratos §4.3 (ADR 0027): o editor simula o perfil sem gravar nada; definição
# inválida responde 200 com eligible false, suggestions [] e os errors.
RSpec.describe "Simulador de oferta", type: :request do
  def body = JSON.parse(response.body)
  after { Rails.cache.clear }

  def definition(offer: { "eligibility" => { "gte" => ["profile.age", 60] } }, suggestions: nil)
    catalog_definition("saude-do-idoso", offer: offer, suggestions: suggestions)
  end

  def simulate(params) = post("/authoring/protocols/simulate_offer", params: params, as: :json)

  it "autor e revisor simulam; os demais, 403 missing_role" do
    %w[protocol_author protocol_reviewer].each do |role|
      sign_in_as(staff_with("#{role}-sim@cidade.gov.br", role))
      simulate(definition: definition, profile: { age: 62, sex: "female" })
      expect(response).to have_http_status(:ok), role
    end
    sign_in_as(staff_with("admin-sim@cidade.gov.br", "municipal_admin"))
    simulate(definition: definition, profile: { age: 62, sex: "female" })
    expect(response).to have_http_status(:forbidden)
    expect(body).to eq("error" => "missing_role")
  end

  it "avalia elegibilidade e sugestões sobre perfil, respostas e resultado" do
    sign_in_as(staff_with("autor-sim@cidade.gov.br", "protocol_author"))
    create_default_protocol!
    suggestions = [ { "protocol" => StartTriage::DEFAULT_PROTOCOL_NAME, "when" => { "gte" => ["outcome.score", 4] } },
                    { "protocol" => "fantasma", "when" => { "eq" => ["q1", "true"] } } ]
    expect do
      simulate(definition: definition(suggestions: suggestions), profile: { age: 62, sex: "female", neighborhood_id: nil },
               answers: { q1: "false" }, outcome: { tier: "media", score: 4, priority: 5 })
    end.not_to change { [ ProtocolDefinition.count, TriageSuggestion.count, DomainEvent.count ] }
    expect(body).to eq(
      "eligible" => true, "eligibility_text" => "idade ≥ 60",
      "suggestions" => [ { "protocol" => StartTriage::DEFAULT_PROTOCOL_NAME, "matches" => true },
                         { "protocol" => "fantasma", "matches" => false } ],
      "errors" => [], "warnings" => [ "suggestion protocol 'fantasma' does not exist in this city" ]
    )

    simulate(definition: definition, profile: { age: 59, sex: "female" })
    expect(body).to include("eligible" => false, "suggestions" => [])
  end

  it "definição inválida: 200, eligible false, suggestions [] e os errors do gate" do
    sign_in_as(staff_with("autor2-sim@cidade.gov.br", "protocol_author"))
    bad = definition(offer: { "eligibility" => { "gte" => ["outcome.score", 1] } },
                     suggestions: [ { "protocol" => "saude-do-idoso", "when" => { "eq" => ["q1", "true"] } } ])
    simulate(definition: bad, profile: { age: 62, sex: "female" }, outcome: { score: 10 })
    expect(response).to have_http_status(:ok)
    expect(body).to include("eligible" => false, "suggestions" => [])
    expect(body["errors"]).to include("offer.eligibility: condition variable 'outcome.score' is not allowed here",
                                      "suggestions[0]: suggestion points to the protocol itself")

    simulate(definition: definition(offer: { "title" => "x" * 61 }), profile: { age: 62, sex: "female" })
    expect(response).to have_http_status(:ok)
    expect(body["errors"]).to include(a_string_starting_with("schema: /offer/title"))
    expect(body["eligible"]).to be(false)
  end
  it "definição que não é objeto, ou ausente: 200 com o erro, nunca 4xx/500" do
    sign_in_as(staff_with("autor3-sim@cidade.gov.br", "protocol_author"))
    [ { definition: "texto" }, { definition: [ 1, 2 ] }, {} ].each do |extra|
      simulate(extra.merge(profile: { age: 62, sex: "female" }))
      expect(response).to have_http_status(:ok), extra.inspect
      expect(body).to include("eligible" => false, "suggestions" => [], "errors" => [ "schema: (root) object" ],
                              "warnings" => [])
    end
  end
end
