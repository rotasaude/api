require "rails_helper"

RSpec.describe SessionsController, "MFA flow para operador", type: :request do
  let!(:operator) do
    u = User.create!(email_address: "ops@example.org", password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    u
  end

  before { allow_any_instance_of(User).to receive(:operator?).and_return(true) }

  it "create devolve mfa_required quando user é operador" do
    post "/session", params: { email_address: "ops@example.org", password: "secret123" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["mfa_required"]).to be(true)
  end

  it "challenge_totp com código válido finaliza o login" do
    post "/session", params: { email_address: "ops@example.org", password: "secret123" }
    session_id = JSON.parse(response.body)["session_id"]
    code = ROTP::TOTP.new(operator.otp_secret).now
    post "/session/challenge", params: { session_id: session_id, code: code }
    expect(response).to have_http_status(:ok)
  end
end
