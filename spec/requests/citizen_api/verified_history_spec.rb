require "rails_helper"

RSpec.describe "Verified citizen history", type: :request do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
    Rails.cache.clear
  end
  after { Current.reset }

  let!(:mine) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let!(:family) { Citizen.create!(cpf: "52998224725", phone: "+5541911112222") }
  let(:verifier) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:admin) { User.create!(email_address: "admin@cidade.gov.br", password: "senha-segura-123") }
  def body = JSON.parse(response.body)

  def triage_for(citizen)
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "false", idempotency_key: SecureRandom.uuid)
    started[:triage]
  end

  def verify(citizen)
    Citizens::Verify.call(cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true, by: verifier)
                    .payload[:verification]
  end

  it "par verificado vê as triagens de todos os pares do CPF, marcadas com o celular de origem" do
    own = triage_for(mine)
    other = triage_for(family)
    verify(mine)
    sign_in_citizen("+5541998765432")
    get "/citizen/triages", params: { citizen_id: mine.id }
    expect(body["citizen"]["verified_at"]).to be_present
    rows = body["triages"].index_by { |t| t["id"] }
    expect(rows.keys).to contain_exactly(own.id, other.id)
    expect(rows[own.id]["origin_phone_masked"]).to be_nil
    expect(rows[other.id]["origin_phone_masked"]).to eq("(**) *****-2222")
    expect(rows[other.id]["consent_active"]).to be(false)
  end

  it "par declarado do mesmo CPF continua vendo só as próprias" do
    triage_for(mine)
    other = triage_for(family)
    verify(mine)
    sign_in_citizen("+5541911112222")
    get "/citizen/triages", params: { citizen_id: family.id }
    expect(body["triages"].map { |t| t["id"] }).to eq([other.id])
    expect(body["citizen"]["verified_at"]).to be_nil
  end

  it "depois de desfeita a validação, volta a ver só as próprias" do
    own = triage_for(mine)
    triage_for(family)
    Citizens::RevokeVerification.call(verification: verify(mine), reason: "documento de outra pessoa", by: admin)
    sign_in_citizen("+5541998765432")
    get "/citizen/triages", params: { citizen_id: mine.id }
    expect(body["triages"].map { |t| t["id"] }).to eq([own.id])
  end

  it "não revoga consentimento de triagem de outro par" do
    triage_for(mine)
    other = triage_for(family)
    verify(mine)
    sign_in_citizen("+5541998765432")
    json_post "/citizen/triages/#{other.id}/revoke_consent"
    expect(response).to have_http_status(:forbidden)
    expect(body["error"]).to eq("not_own_triage")
    expect(other.conversation.reload.active_consent).to be_present
  end

  it "celular com um par declarado e outro verificado não vê a triagem de um terceiro par com o mesmo CPF do declarado" do
    citizen_a = mine # CPF X, declarado, celular P
    citizen_b = Citizen.create!(cpf: "11144477735", phone: citizen_a.phone) # CPF Y, celular P
    citizen_c = Citizen.create!(cpf: citizen_a.cpf, phone: "+5541900001111") # CPF X, celular Q
    verify(citizen_b)
    own = triage_for(citizen_a)
    other = triage_for(citizen_c)

    sign_in_citizen(citizen_a.phone)
    get "/citizen/triages/#{other.id}"
    expect(response).to have_http_status(:not_found)

    get "/citizen/triages", params: { citizen_id: citizen_a.id }
    expect(body["triages"].map { |t| t["id"] }).to eq([own.id])
  end

  it "o par verificado abre o detalhe de uma triagem de outro par" do
    triage_for(mine)
    other = triage_for(family)
    verify(mine)
    sign_in_citizen("+5541998765432")
    get "/citizen/triages/#{other.id}"
    expect(response).to have_http_status(:ok)
    expect(body["origin_phone_masked"]).to eq("(**) *****-2222")
  end
end
