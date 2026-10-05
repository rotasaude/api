require "rails_helper"

# Contratos §3.6 (ADR 0027): "Recomendamos também" — só as pendentes nascidas
# desta triagem e ainda em oferta; [] em urgente; nunca para outro par.
RSpec.describe "Sugestões no resultado", type: :request do
  before do
    create_default_protocol!
    active_protocol!("saude-mental-aprofundada", offer: { "title" => "Aprofundamento", "summary" => "Mais perguntas." })
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)
  let(:to_deep) { [ { "protocol" => "saude-mental-aprofundada", "when" => { "gte" => ["outcome.score", 4] } } ] }
  let(:admin) { staff_with("catalogo-#{SecureRandom.hex(3)}@cidade.gov.br") }

  def finish_mental(answer)
    started = start_citizen_triage(protocol_name: "saude-mental")
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: answer, idempotency_key: SecureRandom.uuid
    body["triage_id"]
  end

  it "traz a sugestão nascida desta triagem" do
    active_protocol!("saude-mental", suggestions: to_deep)
    triage_id = finish_mental("true")
    get "/citizen/triages/#{triage_id}"
    expect(body["suggestions"]).to eq([ {
      "suggestion_id" => TriageSuggestion.sole.id, "protocol_name" => "saude-mental-aprofundada",
      "title" => "Aprofundamento", "summary" => "Mais perguntas."
    } ])
  end

  it "protocolo pausado some do resultado" do
    active_protocol!("saude-mental", suggestions: to_deep)
    triage_id = finish_mental("true")
    TriageOffer.create!(protocol_name: "saude-mental-aprofundada", enabled: false, updated_by_user: admin)
    get "/citizen/triages/#{triage_id}"
    expect(body["suggestions"]).to eq([])
  end

  it "urgente: []" do
    active_protocol!("saude-mental", suggestions: to_deep,
                                     priority_when: [ { "when" => { "eq" => ["q1", "true"] }, "priority" => 1 } ])
    triage_id = finish_mental("true")
    get "/citizen/triages/#{triage_id}"
    expect(body["suggestions"]).to eq([])
  end

  it "triagem de outro par do CPF verificado: suggestions []" do
    active_protocol!("saude-mental", suggestions: to_deep)
    mine = profiled_citizen!(age: 30, cpf: "52998224725")
    mine.update!(verification_level: "verified")
    other = profiled_citizen!(age: 30, cpf: "52998224725", phone: "+5541900000000")
    source = completed_triage!(other, "saude-mental")
    TriageSuggestion.create!(citizen: other, source_triage: source, protocol_name: "saude-mental-aprofundada")
    get "/citizen/triages/#{source.id}"
    expect(response).to have_http_status(:ok)
    expect(body["suggestions"]).to eq([])
  end
end
