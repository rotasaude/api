require "rails_helper"

# F-02.9 — painel Conversas do dashboard da cidade: GET /admin/api/conversations.
RSpec.describe "Admin::Api::Conversations", type: :request do
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  def viewer
    user = User.create!(email_address: "conv-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago)
    user
  end

  it "returns the state distribution of the city's web conversations, without citizen data" do
    Conversation.create!(phone: citizen.phone, state: "abandoned", channel: "web", citizen: citizen)
    Conversation.create!(phone: citizen.phone, state: "consented", channel: "web", citizen: citizen)
    sign_in_as(viewer)

    get "/admin/api/conversations", params: { period: "7d" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    data = body.fetch("data")
    expect(data["live"]).to eq(1)
    expect(data["exits"].find { |e| e["key"] == "abandoned" }["count"]).to eq(1)
    expect(data["abandonRate"]).to eq(50.0)
    expect(body).to have_key("as_of")
    expect(response.body).not_to include(citizen.phone)
    expect(response.body).not_to include(citizen.cpf)
  end

  it "refuses a request without a session" do
    get "/admin/api/conversations", params: { period: "7d" }

    expect(response).to have_http_status(:unauthorized)
  end
end
