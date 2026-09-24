require "rails_helper"

RSpec.describe "Citizen verification codes", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "gera o código para um par do celular da sessão" do
    sign_in_citizen("+5541998765432")
    json_post "/citizen/verification_codes", citizen_id: citizen.id
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["code"]).to match(/\A\d{6}\z/)
  end

  it "par de outro celular: 404" do
    sign_in_citizen("+5541911112222")
    json_post "/citizen/verification_codes", citizen_id: citizen.id
    expect(response).to have_http_status(:not_found)
  end

  it "sem sessão: 401" do
    json_post "/citizen/verification_codes", citizen_id: citizen.id
    expect(response).to have_http_status(:unauthorized)
  end
end
