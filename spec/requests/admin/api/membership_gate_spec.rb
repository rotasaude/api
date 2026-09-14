require "rails_helper"

# Revisão 5b M3: Admin::Api só exigia sessão. Um usuário da cidade sem
# membership ativo — auto-provisionado pelo gov.br, ou com o membership revogado
# (RevokeMembership não derruba sessões) — lia todos os painéis da cidade.
RSpec.describe "Admin::Api membership gate", type: :request do
  def endpoints
    %w[
      /admin/api/overview /admin/api/ingestion /admin/api/conversations
      /admin/api/consent /admin/api/triages /admin/api/reports
      /admin/api/classification /admin/api/protocols /admin/api/queues
      /admin/api/events /admin/api/health /admin/api/municipalities
    ] + [ "/admin/api/triages/#{SecureRandom.uuid}/trail", "/admin/api/protocols/#{SecureRandom.uuid}" ]
  end

  def user_with(role: nil, revoked: false)
    user = User.create!(email_address: "gate-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    if role
      Membership.create!(user: user, role: role, granted_at: 2.days.ago, revoked_at: (revoked ? 1.day.ago : nil))
    end
    user
  end

  it "refuses every endpoint to a city user with no membership" do
    sign_in_as(user_with)

    endpoints.each do |path|
      get path, params: { period: "30d" }
      expect(response).to have_http_status(:forbidden), "#{path} respondeu #{response.status}"
      expect(JSON.parse(response.body)).to eq("error" => "no_city_membership")
    end
  end

  it "refuses a user whose only membership was revoked, even with a live session" do
    sign_in_as(user_with(role: "viewer", revoked: true))

    get "/admin/api/reports", params: { period: "30d" }

    expect(response).to have_http_status(:forbidden)
  end

  it "lets every active local role through (positive control)" do
    Membership::ROLES.each do |role|
      sign_in_as(user_with(role: role))
      get "/admin/api/reports", params: { period: "30d" }
      expect(response).to have_http_status(:ok), "#{role} respondeu #{response.status}"
    end
  end

  it "still answers 401, not 403, without a session" do
    get "/admin/api/reports", params: { period: "30d" }
    expect(response).to have_http_status(:unauthorized)
  end
end
