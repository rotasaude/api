require "rails_helper"

RSpec.describe PublicationsController, type: :request do
  let!(:user) do
    u = User.create!(email_address: "pub@example.org", password: "secret123")
    Mfa::Enroll.call(u); u.update!(otp_enabled: true)
    u
  end

  before do
    session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    @session = session
    # Rack::Test::CookieJar não expõe .signed — bypassamos o cookie path
    # e injectamos a sessão direto no Current (padrão de MfaController spec).
    allow_any_instance_of(PublicationsController).to receive(:resume_session) { Current.session = session }
  end

  it "sem step-up recente devolve 401 mfa_required" do
    allow(Protocols::Publish).to receive(:call)
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)["error"]).to eq("mfa_required")
  end

  it "com step-up recente publica" do
    @session.update!(mfa_verified_at: Time.current)
    fake_pd = instance_double(ProtocolDefinition, id: SecureRandom.uuid, name: "dengue", version: 1, status: "published")
    expect(Protocols::Publish).to receive(:call)
      .with(version: "v1", name: nil, by: user)
      .and_return(Result.ok(protocol_definition: fake_pd))
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "ok" => true, "id" => fake_pd.id,
      "protocol" => { "name" => "dengue", "version" => 1, "status" => "published" }
    )
  end

  it "passa o name do corpo ao Publish" do
    @session.update!(mfa_verified_at: Time.current)
    fake_pd = instance_double(ProtocolDefinition, id: SecureRandom.uuid, name: "dengue", version: 1, status: "published")
    expect(Protocols::Publish).to receive(:call)
      .with(version: "v1", name: "dengue", by: user)
      .and_return(Result.ok(protocol_definition: fake_pd))
    post "/protocols/v1/publish", params: { name: "dengue" }
    expect(response).to have_http_status(:ok)
  end

  it "versão inexistente devolve 404" do
    @session.update!(mfa_verified_at: Time.current)
    allow(Protocols::Publish).to receive(:call).and_return(Result.fail(:not_found))
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:not_found)
  end

  it "sem permissão devolve 403 forbidden" do
    @session.update!(mfa_verified_at: Time.current)
    allow(Protocols::Publish).to receive(:call).and_return(Result.fail(:forbidden))
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to eq("error" => "forbidden")
  end

  it "regra de domínio recusada devolve 422 com a mensagem do command" do
    @session.update!(mfa_verified_at: Time.current)
    allow(Protocols::Publish).to receive(:call)
      .and_return(Result.fail(:signatures_missing, message: "falta 1 assinatura de publicação; revisores elegíveis na cidade: 2"))
    post "/protocols/v1/publish"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)).to eq(
      "error" => "signatures_missing",
      "message" => "falta 1 assinatura de publicação; revisores elegíveis na cidade: 2"
    )
  end
end
