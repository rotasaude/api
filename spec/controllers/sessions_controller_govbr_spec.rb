require "rails_helper"

RSpec.describe SessionsController, "gov.br callback (ADR-0011 seam)", type: :request do
  context "auth bem-sucedida (User normal, não operador)" do
    let!(:user) { User.create!(email_address: "fulano@gov.br", password: SecureRandom.base58(16)) }

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

  # No city user can be a platform operator any more (ck_memberships_role has
  # no such role; User#operator? is hardcoded to false — D3, Plan 3 moves the
  # operator grant to the platform). The controller branch on `user.operator?`
  # still exists and still needs to fail closed if it were ever true, so these
  # two scenarios stub `operator?` directly on a real user rather than
  # constructing an invalid Membership — the behaviour under test (what the
  # endpoint does when `operator?` is true) survives unweakened.
  context "operador (operator? stubado) sem MFA enrolled" do
    let!(:user) { User.create!(email_address: "op@gov.br", password: SecureRandom.base58(16)) }

    before do
      allow(Authenticator).to receive(:govbr).and_return(user)
      allow(user).to receive_messages(operator?: true, mfa_enrolled?: false)
    end

    it "retorna 403 mfa_enrollment_required" do
      get "/auth/govbr/callback", params: { code: "valid" }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("mfa_enrollment_required")
    end
  end

  context "operador (operator? stubado) com MFA enrolled — devolve mfa_required" do
    let!(:user) { User.create!(email_address: "op2@gov.br", password: SecureRandom.base58(16)) }

    before do
      allow(Authenticator).to receive(:govbr).and_return(user)
      allow(user).to receive_messages(operator?: true, mfa_enrolled?: true)
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
