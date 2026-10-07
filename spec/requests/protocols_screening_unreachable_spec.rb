require "rails_helper"

# ADR 0030: o protocolo de acolhimento não tem passos; as rotas antigas de
# triagem (/protocols/:name e /protocols/:name/preview) não o enxergam — 404,
# como protocolo sem versão ativa, nunca 500 ao montar o motor de triagem.
RSpec.describe "Rotas antigas de protocolo com o acolhimento", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear; acolhimento! }
  after { Current.reset }

  let(:headers) { { "Authorization" => "Bearer any-token" } }

  it "GET e preview do acolhimento respondem 404" do
    get "/protocols/acolhimento", headers: headers
    expect(response).to have_http_status(:not_found)
    post "/protocols/acolhimento/preview", params: { answers: { "x" => "1" } }, as: :json, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
