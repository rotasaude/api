require "rails_helper"

# Spec §6: conceder e revogar acesso é só por sessão humana, o mantenedor não
# desativa a si mesmo nem o último ativo, e a desativação mata sessões e tokens.
RSpec.describe "Maintainer mutations", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "mm-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let!(:other) do
    Maintainer.create!(email_address: "other-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  def mutate!(query, **variables)
    post "/graphql", params: { query: query, variables: variables }, headers: browser
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  it "invites a maintainer and audits the attempt and its outcome on one correlation id" do
    mutate!('mutation($e: String!) { inviteMaintainer(emailAddress: $e) { ok errors { message } } }',
            e: "novo@rotasaude.app")

    expect(json.dig("data", "inviteMaintainer", "ok")).to be(true)
    invited = Maintainer.find_by(email_address: "novo@rotasaude.app")
    expect(invited.maintainer_invitations.count).to eq(1)

    events = PlatformEvent.where(name: "maintenance.maintainer.invited").last(2)
    expect(events.map { |e| e.payload["outcome"] }).to eq(%w[attempted ok])
    expect(events.map { |e| e.payload["correlation_id"] }.uniq.size).to eq(1)
    expect(events.last.payload["maintainer_id"]).to eq(maintainer.id)
  end

  it "never returns the invitation token" do
    mutate!('mutation($e: String!) { inviteMaintainer(emailAddress: $e) { ok } }', e: "outro@rotasaude.app")

    invitation = Maintainer.find_by(email_address: "outro@rotasaude.app").maintainer_invitations.sole
    expect(response.body).not_to include(invitation.token_digest)
    expect(json.dig("data", "inviteMaintainer").keys).to contain_exactly("ok")
  end

  it "refuses an invalid e-mail as a user error, not a crash" do
    mutate!('mutation($e: String!) { inviteMaintainer(emailAddress: $e) { ok errors { path message } } }', e: "nao-e-email")

    expect(json.dig("data", "inviteMaintainer", "ok")).to be(false)
    expect(json.dig("data", "inviteMaintainer", "errors").first["path"]).to eq("emailAddress")
    expect(PlatformEvent.where(name: "maintenance.maintainer.invited").last.payload["outcome"]).to eq("rejected")
  end

  it "deactivates another maintainer, killing sessions and tokens" do
    other.maintainer_sessions.create!(mfa_verified_at: Time.current, last_seen_at: Time.current)
    MaintenanceToken.issue!(maintainer: other, name: "ci", access: "read", city_slugs: [], expires_at: 5.days.from_now)

    mutate!('mutation($id: ID!) { deactivateMaintainer(id: $id) { ok errors { message } } }', id: other.id)

    expect(json.dig("data", "deactivateMaintainer", "ok")).to be(true)
    expect(other.reload.active?).to be(false)
    expect(MaintainerSession.where(maintainer_id: other.id)).to be_empty
    expect(MaintenanceToken.where(maintainer_id: other.id).live).to be_empty
    expect(PlatformEvent.where(name: "maintenance.maintainer.deactivated").last.payload["outcome"]).to eq("ok")
  end

  it "refuses deactivating myself and refuses leaving no active maintainer" do
    mutate!('mutation($id: ID!) { deactivateMaintainer(id: $id) { ok errors { message } } }', id: maintainer.id)
    expect(json.dig("data", "deactivateMaintainer", "ok")).to be(false)
    expect(maintainer.reload.active?).to be(true)

    mutate!('mutation($id: ID!) { deactivateMaintainer(id: $id) { ok } }', id: other.id)
    other_two = Maintainer.where(deactivated_at: nil).where.not(id: maintainer.id)
    expect(other_two).to be_empty

    # Agora `maintainer` é o último ativo: nem outro mantenedor poderia removê-lo.
    expect { maintainer.deactivate! }.to raise_error(Maintainer::LastActive)
  end
end
