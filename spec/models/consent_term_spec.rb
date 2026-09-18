require "rails_helper"

# `consents.version` é INTEGER: um termo cuja versão não é inteira não teria
# como ser registrado no consentimento, e quebraria a ordenação numérica de
# Consents.current_version.
RSpec.describe ConsentTerm, type: :model do
  def term(version)
    described_class.new(version: version, body: "termo", published_at: Time.current)
  end

  it "accepts an integer version" do
    expect(term("10")).to be_valid
  end

  it "rejects a version that is not a plain non-negative integer" do
    %w[v2 1.1 -1 abc].each do |version|
      expect(term(version)).not_to be_valid, "expected #{version.inspect} to be invalid"
    end
  end
end
