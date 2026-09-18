require "rails_helper"

# `consents.version` é INTEGER e Consents.current_version é String: a
# comparação de Conversation#consented? não pode ser Integer == String.
RSpec.describe "Conversation#consented?", type: :model do
  def consented_with!(version)
    conversation = Conversation.create!(phone: "+5541980000099", state: "consented")
    Consent.create!(
      conversation: conversation, version: version, policy_text_sha: "sha",
      channel: "whatsapp", given_at: 1.minute.ago
    )
    conversation
  end

  it "is true when the active consent is on the current term" do
    ConsentTerm.create!(version: "9", body: "termo", published_at: Time.current)
    ConsentTerm.create!(version: "10", body: "termo", published_at: Time.current)

    expect(consented_with!(10).consented?).to be(true)
  end

  it "is false when the active consent is on an older term" do
    ConsentTerm.create!(version: "9", body: "termo", published_at: Time.current)
    ConsentTerm.create!(version: "10", body: "termo", published_at: Time.current)

    expect(consented_with!(9).consented?).to be(false)
  end

  it "is true on the fallback version when the city has no term" do
    expect(consented_with!(1).consented?).to be(true)
  end
end
