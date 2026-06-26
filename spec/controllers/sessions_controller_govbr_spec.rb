require "rails_helper"

RSpec.describe SessionsController, "gov.br callback (ADR-0022 seam)", type: :request do
  before do
    allow(Platform).to receive(:audit)
  end

  context "auth bem-sucedida (User normal, não operador)" do
    let!(:user) do
      ApplicationRecord.connected_to(role: :admin) do
        User.create!(email_address: "fulano@gov.br", password: SecureRandom.base58(16))
      end
    end

    before do
      allow(Authenticator).to receive(:govbr).with(code: "valid").and_return(user)
    end

    it "retorna 201 + user serializado" do
      get "/auth/govbr/callback", params: { code: "valid" }
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["email_address"]).to eq("fulano@gov.br")
    end
  end

  context "código inválido ou usuário não autenticado" do
    before { allow(Authenticator).to receive(:govbr).and_return(nil) }

    it "retorna 401" do
      get "/auth/govbr/callback", params: { code: "ruim" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("govbr_unauthenticated")
    end
  end

  context "integração com gov.br falhou (network/token)" do
    before do
      allow(Authenticator).to receive(:govbr)
        .and_raise(Authenticator::GovBr::IntegrationError, "boom")
    end

    it "retorna 502" do
      get "/auth/govbr/callback", params: { code: "qualquer" }
      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["error"]).to eq("govbr_integration_error")
    end
  end

  context "operador sem MFA enrolled" do
    let!(:user) do
      ApplicationRecord.connected_to(role: :admin) do
        u = User.create!(email_address: "op@gov.br", password: SecureRandom.base58(16))
        Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
        u
      end
    end

    before do
      allow(Authenticator).to receive(:govbr).and_return(user)
      allow_any_instance_of(User).to receive(:mfa_enrolled?).and_return(false)
    end

    it "retorna 403 mfa_enrollment_required" do
      get "/auth/govbr/callback", params: { code: "valid" }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("mfa_enrollment_required")
    end
  end

  context "operador com MFA enrolled — devolve mfa_required" do
    let!(:user) do
      ApplicationRecord.connected_to(role: :admin) do
        u = User.create!(email_address: "op2@gov.br", password: SecureRandom.base58(16))
        Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
        u
      end
    end

    before do
      allow(Authenticator).to receive(:govbr).and_return(user)
      allow_any_instance_of(User).to receive(:mfa_enrolled?).and_return(true)
    end

    it "retorna 200 com mfa_required + session_id" do
      get "/auth/govbr/callback", params: { code: "valid" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["mfa_required"]).to be(true)
      expect(body["session_id"]).to be_present
    end
  end
end
