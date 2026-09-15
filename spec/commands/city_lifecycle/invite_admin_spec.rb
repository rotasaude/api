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
end
