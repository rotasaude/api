require "rails_helper"

RSpec.describe "Preferências de contato do cidadão", type: :request do
  def body = JSON.parse(response.body)

  let(:phone) { "+5541998765432" }
  let!(:ana) { person!(phone: phone, cpf: "52998224725") }
  let!(:bia) { person!(phone: phone, cpf: "11144477735") }

  it "lista cada pessoa do telefone com os padrões e a chave da cidade" do
    CityProfile.create!(name: "Curitiba", campaigns_sms_enabled: true)
    sign_in_citizen(phone)
    get "/citizen/contact_preferences"
    expect(body).to eq(
      "sms_available" => true,
      "people" => [
        { "citizen_id" => ana.id, "cpf_masked" => ana.cpf_masked, "sms_opt_in" => false, "notices_muted" => false },
        { "citizen_id" => bia.id, "cpf_masked" => bia.cpf_masked, "sms_opt_in" => false, "notices_muted" => false }
      ]
    )
  end

  it "altera a pessoa do telefone e devolve a entrada" do
    sign_in_citizen(phone)
    put "/citizen/contact_preferences/#{bia.id}", params: { sms_opt_in: true }, as: :json
    expect(body).to eq("citizen_id" => bia.id, "cpf_masked" => bia.cpf_masked, "sms_opt_in" => true, "notices_muted" => false)
    get "/citizen/contact_preferences"
    expect(body["sms_available"]).to be(false)
    expect(body["people"].map { |p| p["sms_opt_in"] }).to eq([ false, true ])
  end

  it "pessoa de outro telefone, ou id que não é UUID: 404; corpo inválido: 422 invalid_preferences" do
    other = person!
    sign_in_citizen(phone)
    [ other.id, "nao-e-uuid" ].each do |id|
      put "/citizen/contact_preferences/#{id}", params: { sms_opt_in: true }, as: :json
      expect(response).to have_http_status(:not_found)
    end
    expect(CitizenContactPreference.for(other.id)).to be_new_record
    put "/citizen/contact_preferences/#{ana.id}", params: { sms_opt_in: "sim" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_preferences" ])
  end

  it "sem sessão: 401" do
    get "/citizen/contact_preferences"
    expect(response).to have_http_status(:unauthorized)
  end
end
