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

  describe ".cancel?" do
    %w[sair parar cancelar encerrar].each do |word|
      it "is true for #{word}" do
        expect(described_class.cancel?(word)).to be(true)
      end
    end

    it "is false for 'não' (a valid boolean answer)" do
      expect(described_class.cancel?("não")).to be(false)
    end

    it "is false for an ordinary answer / blank / nil" do
      expect(described_class.cancel?("sim")).to be(false)
      expect(described_class.cancel?("qualquer coisa")).to be(false)
      expect(described_class.cancel?("")).to be(false)
      expect(described_class.cancel?(nil)).to be(false)
    end
  end

  describe ".revoke_intent?" do
    ["revogar", "revogar consentimento", "revogar meu consentimento", "apagar meus dados"].each do |phrase|
      it "is true for #{phrase.inspect}" do
        expect(described_class.revoke_intent?(phrase)).to be(true)
      end
    end

    it "is false for cancel words (those are cancel?, not revoke)" do
      %w[cancelar sair parar encerrar].each do |w|
        expect(described_class.revoke_intent?(w)).to be(false)
      end
    end

    it "is false for 'não'/'sim'/ordinary/blank/nil" do
      expect(described_class.revoke_intent?("não")).to be(false)
      expect(described_class.revoke_intent?("sim")).to be(false)
      expect(described_class.revoke_intent?("qualquer coisa")).to be(false)
      expect(described_class.revoke_intent?("")).to be(false)
      expect(described_class.revoke_intent?(nil)).to be(false)
    end
  end

  # `consent_terms.version` é STRING e `consents.version` é INTEGER: a vigente
  # é a de maior valor NUMÉRICO (MAX de string diria que "9" > "10"), e sai
  # sempre como String — inclusive no fallback sem termo.
  describe ".current_version" do
    def term!(version)
      ConsentTerm.create!(version: version, body: "termo", published_at: Time.current)
    end

    it "orders versions numerically, so \"10\" beats \"9\"" do
      term!("9")
      term!("10")

      expect(described_class.current_version).to eq("10")
    end

    it "does not depend on insertion order" do
      term!("10")
      term!("9")

      expect(described_class.current_version).to eq("10")
    end

    it "falls back to \"1\" as a String when the city has no term" do
      expect(ConsentTerm.count).to eq(0)

      expect(described_class.current_version).to eq("1")
    end
  end
end
