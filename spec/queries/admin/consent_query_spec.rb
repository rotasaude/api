require "rails_helper"

# F-05.7: "Concedidos" conta todo consentimento dado no período, mesmo o que foi
# revogado depois; "Revogados" conta revogações no período. Recusa não tem
# registro na web (ADR 0017: sem consentimento nada é gravado), então sai nil.
RSpec.describe Admin::ConsentQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def consent!(version:, given_at:, revoked_at: nil)
    conv = Conversation.create!(phone: "+55419#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}", state: "consented")
    Consent.create!(conversation: conv, version: version, policy_text_sha: "sha", channel: "web",
                    given_at: given_at, revoked_at: revoked_at)
  end

  before do
    consent!(version: 2, given_at: 2.days.ago)
    consent!(version: 2, given_at: 2.days.ago, revoked_at: 1.day.ago)
    consent!(version: 1, given_at: 3.days.ago)
    consent!(version: 1, given_at: 40.days.ago, revoked_at: 1.day.ago)
    consent!(version: 1, given_at: 40.days.ago)
  end

  it "counts every consent given in the period, including the ones revoked later" do
    out = described_class.call(period: period)

    expect(out[:given]).to eq(3)
  end

  it "counts revocations that happened in the period, whenever the consent was given" do
    out = described_class.call(period: period)

    expect(out[:revoked]).to eq(2)
  end

  it "splits the consents given in the period by term version, newest first" do
    out = described_class.call(period: period)

    expect(out[:byVersion]).to eq([
      { version: "v2", given: 2, share: 67 },
      { version: "v1", given: 1, share: 33 }
    ])
  end

  it "reports declined as nil: the web channel records nothing without consent" do
    expect(described_class.call(period: period)[:declined]).to be_nil
  end
end
