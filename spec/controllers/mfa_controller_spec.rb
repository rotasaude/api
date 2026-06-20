require "rails_helper"

RSpec.describe MfaController, type: :request do
  let!(:user) { User.create!(email_address: "dan@example.org", password: "secret123") }

  before do
    @enroll = Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    @session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    allow_any_instance_of(MfaController).to receive(:resume_session) do
      Current.session = @session
    end
  end

  it "step_up com TOTP correto carimba mfa_verified_at" do
    code = ROTP::TOTP.new(user.otp_secret).now
    post "/mfa/step_up", params: { code: code }
    expect(response).to have_http_status(:ok)
    expect(@session.reload.mfa_verified_at).to be_within(5.seconds).of(Time.current)
  end
end
