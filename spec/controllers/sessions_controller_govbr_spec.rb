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

  # Operador de plataforma não loga pela cidade: loga no console, host admin.*
  # (Operators::SessionsController, spec/requests/operators/sessions_spec.rb). O
  # que resta a garantir aqui é que um usuário da cidade com MFA cadastrado NÃO
  # recebe mfa_required no callback — o TOTP da cidade é step-up (publicação),
  # não login.
  context "usuário da cidade com MFA cadastrado" do
    let!(:user) do
      u = User.create!(email_address: "mfa@gov.br", password: SecureRandom.base58(16))
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
      u
    end

    before { allow(Authenticator).to receive(:govbr).and_return(user) }

    it "retorna 201 com a sessão, sem mfa_required" do
      get "/auth/govbr/callback", params: { code: "valid" }

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body).not_to have_key("mfa_required")
      expect(body).to include("operator" => false, "mfa_enrolled" => true)
    end
  end
end
