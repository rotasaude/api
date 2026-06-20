require "rails_helper"

RSpec.describe PublicationsController, type: :request do
  let!(:user) do
    u = User.create!(email_address: "pub@example.org", password: "secret123")
    Mfa::Enroll.call(u); u.update!(otp_enabled: true)
    u
  end
  let!(:muni) { create(:municipality) }

  before do
    session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    @session = session
    # Rack::Test::CookieJar não expõe .signed — bypassamos o cookie path
    # e injectamos a sessão direto no Current (padrão de MfaController spec).
    allow_any_instance_of(PublicationsController).to receive(:resume_session) { Current.session = session }
    allow_any_instance_of(PublicationsController).to receive(:current_municipality).and_return(muni)
  end

  it "sem step-up recente devolve 401 mfa_required" do
    allow(Protocols::Publish).to receive(:call)
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)["error"]).to eq("mfa_required")
  end

  it "com step-up recente publica" do
    @session.update!(mfa_verified_at: Time.current)
    expect(Protocols::Publish).to receive(:call).with(version: "v1", by: user)
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:ok)
  end
end
