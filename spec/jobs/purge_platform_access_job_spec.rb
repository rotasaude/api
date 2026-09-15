require "rails_helper"

RSpec.describe PurgePlatformAccessJob, type: :job do
  let(:city) { create(:city) }
  let(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  it "deletes grants expired for more than a day and keeps the others" do
    old    = CityGrant.create!(city: city, kind: "operator", subject_id: operator.id, expires_at: 25.hours.ago)
    recent = CityGrant.create!(city: city, kind: "operator", subject_id: operator.id, expires_at: 23.hours.ago)
    live   = CityGrant.create!(city: city, kind: "user", subject_id: SecureRandom.uuid, expires_at: 1.minute.from_now)

    described_class.perform_now

    expect(CityGrant.where(id: [ old, recent, live ].map(&:id)).pluck(:id)).to contain_exactly(recent.id, live.id)
  end

  it "deletes operator sessions that can no longer authenticate and keeps the usable ones" do
    stale_pending = operator.operator_sessions.create!(created_at: (OperatorAuthentication::PENDING_MFA_WINDOW + 1.minute).ago)
    fresh_pending = operator.operator_sessions.create!
    expired       = operator.operator_sessions.create!(mfa_verified_at: (OperatorAuthentication::OPERATOR_SESSION_TTL + 1.minute).ago)
    verified      = operator.operator_sessions.create!(mfa_verified_at: 1.hour.ago)

    described_class.perform_now

    expect(OperatorSession.where(id: [ stale_pending, fresh_pending, expired, verified ].map(&:id)).pluck(:id))
      .to contain_exactly(fresh_pending.id, verified.id)
  end
end
