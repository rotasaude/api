require "rails_helper"

# Uma sessão só enxerga os cidadãos do próprio telefone. Id de outro telefone é
# 404, nunca 403: a resposta não confirma que o id existe.
RSpec.describe "Citizen isolation", type: :request do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo", published_at: Time.current)
  end
  after { Current.reset; Rails.cache.clear }

  let!(:other) do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541911112222")
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: "1", session_id: "x").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "false", idempotency_key: "k")
    { citizen: citizen, conversation: started[:conversation], triage: started[:triage] }
  end

  before { sign_in_citizen("+5541998765432") }

  it "não lista pessoas de outro telefone, nem com o mesmo CPF" do
    get "/citizen/people"
    expect(JSON.parse(response.body)["people"]).to eq([])
  end

  it "404 para cidadão, conversa e triagem de outro telefone" do
    get "/citizen/triages", params: { citizen_id: other[:citizen].id }
    expect(response).to have_http_status(:not_found)

    json_post "/citizen/conversations", citizen_id: other[:citizen].id, consent_version: "1"
    expect(response).to have_http_status(:not_found)

    json_post "/citizen/conversations/#{other[:conversation].id}/answers", answer: "true", idempotency_key: "z"
    expect(response).to have_http_status(:not_found)

    get "/citizen/triages/#{other[:triage].id}"
    expect(response).to have_http_status(:not_found)

    json_post "/citizen/triages/#{other[:triage].id}/revoke_consent"
    expect(response).to have_http_status(:not_found)
  end

  it "o mesmo CPF digitado neste telefone vira outro cidadão, sem ver as triagens do primeiro" do
    json_post "/citizen/conversations", cpf: "529.982.247-25", consent_version: "1"
    mine = JSON.parse(response.body)["citizen_id"]
    expect(mine).not_to eq(other[:citizen].id)
    get "/citizen/triages", params: { citizen_id: mine }
    expect(JSON.parse(response.body)["triages"].map { |t| t["id"] }).not_to include(other[:triage].id)
  end
end
