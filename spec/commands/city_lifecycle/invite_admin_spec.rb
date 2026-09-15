require "rails_helper"

# Convite (ou reconvite) do primeiro municipal_admin, extraído de
# ProvisionCityJob#seed para ser compartilhado com a rake city:invite_admin
# (rodada de hardening, pre-Plano 6). A cidade de teste (TEST_CITY_A) já está
# conectada pelo harness (spec/support/city_test_databases.rb) — não precisa
# de provision_city!, é só mais uma cidade dentro da MESMA sessão.
RSpec.describe CityLifecycle::InviteAdmin do
  let(:email) { "prefeita@cidade.gov.br" }

  # InviteMember publica user.invited em DomainEvents, que exige Current.city
  # setado (Ruling R18) — igual spec/commands/invite_member_spec.rb.
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "reuses a pending invitation instead of creating a new one" do
    pending_invitation = InviteMember.call(email: email, role: "municipal_admin", invited_by: nil).payload[:invitation]

    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.ok?).to be(true)
    expect(Invitation.count).to eq(1)
    expect(result.payload[:mail_args]).to eq(
      email_address: email,
      accept_url: CityDashboardUrl.invitation(TEST_CITY_A, token: pending_invitation.token)
    )
  end

  it "creates a new invitation when the pending one expired" do
    expired = InviteMember.call(email: email, role: "municipal_admin", invited_by: nil).payload[:invitation]
    expired.update_columns(expires_at: 1.minute.ago)

    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.ok?).to be(true)
    expect(Invitation.count).to eq(2)
    fresh = Invitation.pending.sole
    expect(fresh.token).not_to eq(expired.token)
    expect(result.payload[:mail_args]).to eq(
      email_address: email,
      accept_url: CityDashboardUrl.invitation(TEST_CITY_A, token: fresh.token)
    )
  end

  it "creates a new invitation when the pending one was already accepted" do
    accepted = InviteMember.call(email: email, role: "municipal_admin", invited_by: nil).payload[:invitation]
    accepted.update_columns(accepted_at: Time.current)

    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.ok?).to be(true)
    expect(Invitation.count).to eq(2)
    fresh = Invitation.pending.sole
    expect(fresh.token).not_to eq(accepted.token)
    expect(result.payload[:mail_args]).to eq(
      email_address: email,
      accept_url: CityDashboardUrl.invitation(TEST_CITY_A, token: fresh.token)
    )
  end

  it "returns the invitation id in the payload, for the audit trail" do
    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.payload[:invitation_id]).to eq(Invitation.pending.sole.id)
  end

  # M2 (hardening review): city:invite_admin exists only to re-invite a
  # stalled FIRST admin — a city with an active municipal_admin membership
  # already went through onboarding, so re-inviting would mint a second,
  # unrelated admin invitation instead of resuming a stalled one.
  it "refuses and writes nothing when the city already has an active municipal_admin membership" do
    admin = User.create!(email_address: "already-admin@cidade.gov.br", password: "secret123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: Time.current)

    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.failure?).to be(true)
    expect(result.reason).to eq(:admin_exists)
    expect(Invitation.count).to eq(0)
  end

  it "still allows a re-invite when the only municipal_admin membership was revoked" do
    admin = User.create!(email_address: "ex-admin@cidade.gov.br", password: "secret123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: 1.year.ago, revoked_at: 1.day.ago)

    result = described_class.call(city: TEST_CITY_A, email: email)

    expect(result.ok?).to be(true)
    expect(Invitation.count).to eq(1)
  end
end

# M1 (hardening review): two concurrent runs (two rakes, or a rake racing a
# ProvisionCityJob retry) must not create two live invitations for the same
# email/role. Real threads racing against the real TEST_CITY_A database (not
# transactional fixtures — see provision_city_job_spec.rb/backup_spec.rb for
# the same pattern) is the only way to actually exercise the Postgres
# advisory lock.
RSpec.describe "CityLifecycle::InviteAdmin concurrency safety (M1)" do
  self.use_transactional_tests = false

  let(:email) { "concorrente-#{SecureRandom.hex(6)}@cidade.gov.br" }

  # use_transactional_tests = false means these writes really commit to
  # TEST_CITY_A's database (needed to exercise a real Postgres advisory
  # lock across threads) — clean up everything this example commits so it
  # doesn't leak into other specs sharing TEST_CITY_A (e.g. InviteMember's
  # own DomainEvent.find_by!("user.invited") would otherwise pick up a
  # leftover row from here).
  after do
    CityConnection.with(TEST_CITY_A) do
      Invitation.where(email: email.downcase).delete_all
      DomainEvent.where(name: "user.invited").where("payload->>'email' = ?", email).delete_all
    end
  end

  it "creates exactly one pending invitation when two callers race for the same email/role" do
    ready = Queue.new
    go = Queue.new
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        ready << true
        go.pop
        results << CityLifecycle::InviteAdmin.call(city: TEST_CITY_A, email: email)
      end
    end

    2.times { ready.pop }
    2.times { go << true }
    threads.each(&:join)

    outcomes = Array.new(2) { results.pop }
    expect(outcomes).to all(satisfy(&:ok?))

    CityConnection.with(TEST_CITY_A) do
      expect(Invitation.where(email: email.downcase, role: "municipal_admin").count).to eq(1)
    end
  end
end
