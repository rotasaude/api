require "rails_helper"

# Invariante de fechamento do módulo 06 (#4): a sessão do cidadão (cookie
# citizen_session, canal web) nunca abre endpoint de servidor da cidade. São
# cookies e tabelas diferentes; aqui a prova pela porta da frente.
RSpec.describe "Sessão de cidadão em endpoint de servidor", type: :request do
  before { sign_in_citizen("+5541998765432") }

  it "GET /session: 401" do
    get "/session", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "GET /admin/api/overview: 401" do
    get "/admin/api/overview", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "GET /setup/memberships: 401" do
    get "/setup/memberships", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "POST /setup/invitations: 401 e nenhum convite" do
    expect { post "/setup/invitations", params: { email: "x@example.org", role: "viewer" }, as: :json }
      .not_to change(Invitation, :count)
    expect(response).to have_http_status(:unauthorized)
  end
end
