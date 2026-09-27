require "rails_helper"

# F-06.1: login por senha da cidade — teto de tentativas por IP e logout.
RSpec.describe "Sessão de usuário da cidade", type: :request do
  let!(:user) { User.create!(email_address: "login-#{SecureRandom.hex(3)}@example.org", password: "secret123") }

  it "a 11ª tentativa de login em 3 minutos leva 429 too_many_requests" do
    # O cache do ambiente de teste é :null_store, que nunca conta; troca por um
    # real só aqui (mesmo padrão de spec/requests/citizen_api/check_in_codes_spec.rb).
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    10.times { post "/session", params: { email_address: user.email_address, password: "errada" }, as: :json }
    expect(response).to have_http_status(:unauthorized)

    post "/session", params: { email_address: user.email_address, password: "secret123" }, as: :json

    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)).to eq("error" => "too_many_requests")
    expect(user.sessions.count).to eq(0)
  end

  it "DELETE /session encerra a sessão: a linha some e o cookie deixa de autenticar" do
    session = sign_in_as(user)
    get "/session", as: :json
    expect(response).to have_http_status(:ok)

    delete "/session"

    expect(response).to have_http_status(:no_content)
    expect(Session.exists?(session.id)).to be(false)
    get "/session", as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
