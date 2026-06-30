require "rails_helper"

RSpec.describe Consents do
  describe ".interpret" do
    it "maps the give button id to :give" do
      expect(described_class.interpret(Consents::GIVE_ID)).to eq(:give)
    end

    it "maps the revoke button id to :revoke" do
      expect(described_class.interpret(Consents::REVOKE_ID)).to eq(:revoke)
    end

    it "still maps free-text affirmation to :give" do
      expect(described_class.interpret("sim")).to eq(:give)
    end

    it "still maps free-text refusal to :revoke" do
      expect(described_class.interpret("não")).to eq(:revoke)
    end

    it "returns :unknown for unrecognized text" do
      expect(described_class.interpret("talvez")).to eq(:unknown)
    end

    it "returns :unknown for blank and nil" do
      expect(described_class.interpret("")).to eq(:unknown)
      expect(described_class.interpret(nil)).to eq(:unknown)
    end
  end
end
