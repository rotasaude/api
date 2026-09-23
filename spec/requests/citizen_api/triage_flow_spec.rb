require "rails_helper"

RSpec.describe "Citizen triage flow", type: :request do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen
  end
  after { Current.reset; Rails.cache.clear }

  def body = JSON.parse(response.body)

  def start_new(cpf = "529.982.247-25")
    json_post "/citizen/conversations", cpf: cpf, consent_version: "1"
    body
  end

  it "mostra o termo vigente" do
    get "/citizen/consent_term"
    expect(body).to eq("version" => "1", "body" => "Termo de teste")
  end

  it "faz a triagem inteira e lista o resultado" do
    started = start_new
    expect(response).to have_http_status(:created)
    expect(started["step"]).to include("step_id" => "tosse", "index" => 1, "can_undo" => false)

    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true", idempotency_key: "a1"
    expect(body).to include("status" => "in_progress")
    expect(body["step"]).to include("step_id" => "febre", "can_undo" => true)

    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true", idempotency_key: "a2"
    expect(body).to include("status" => "completed")
    triage_id = body["triage_id"]

    get "/citizen/people"
    person = body["people"].sole
    expect(person).to include("cpf_masked" => "***.982.247-**", "verification_level" => "declared")

    get "/citizen/triages", params: { citizen_id: person["id"] }
    expect(body["triages"].sole).to include("id" => triage_id, "status" => "completed", "tier" => "alta")

    get "/citizen/triages/#{triage_id}"
    expect(body).to include("id" => triage_id, "consent_active" => true)
  end

  it "voltar desfaz a última resposta" do
    started = start_new
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true", idempotency_key: "a1"
    json_post "/citizen/conversations/#{started['conversation_id']}/undo"
    expect(body["step"]).to include("step_id" => "tosse", "can_undo" => false)
  end

  it "retoma a conversa em andamento com 200" do
    started = start_new
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true", idempotency_key: "a1"
    json_post "/citizen/conversations", citizen_id: started["citizen_id"], consent_version: "1"
    expect(response).to have_http_status(:ok)
    expect(body).to include("resumed" => true)
    expect(body["step"]).to include("step_id" => "febre")
  end

  it "resposta fora do esperado: 422 e nada muda" do
    started = start_new
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "banana", idempotency_key: "a1"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_answer")
    expect(Triage.find(started["step"]["triage_id"]).answers).to eq({})
  end

  it "CPF inválido: 422" do
    start_new("111.111.111-11")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_cpf")
  end

  it "termo desatualizado: 409" do
    json_post "/citizen/conversations", cpf: "529.982.247-25", consent_version: "0"
    expect(response).to have_http_status(:conflict)
    expect(body["error"]).to eq("consent_outdated")
  end

  it "revogar o consentimento anonimiza pelo fluxo de sempre" do
    started = start_new
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "false", idempotency_key: "a1"
    triage_id = body["triage_id"]
    json_post "/citizen/triages/#{triage_id}/revoke_consent"
    expect(response).to have_http_status(:ok)
    expect(body["consent_active"]).to be(false)
    expect(DomainEvent.where(name: "consent.revoked")).to exist
  end

  it "responder sem idempotency_key: 422" do
    started = start_new
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("idempotency_key_required")
  end
end
