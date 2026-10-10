require "rails_helper"

# ADR 0033: marca por nome normalizado, palavra inteira no começo do
# ingrediente; em associação, qualquer ingrediente marca; o texto livre é
# varrido por palavra inteira; a lista de controle mais restritiva vence.
RSpec.describe Medications::Substances do
  let(:matcher) do
    described_class::Matcher.new(antimicrobials: %w[AMOXICILINA CIPROFLOXACINO SULFAMETOXAZOL],
                                 controlled: { "DIAZEPAM" => "B1", "CODEINA" => "A2", "FLUOXETINA" => "C1" })
  end

  it "normaliza" do
    expect(described_class.key(" Codeína  fosfato ")).to eq("CODEINA FOSFATO")
    expect(described_class.key("ÁCIDO FÓLICO")).to eq("ACIDO FOLICO")
  end

  it "marca por ingrediente, com sal e em associação" do
    expect(matcher.flags_for([ "CIPROFLOXACINO CLORIDRATO" ])).to have_attributes(antimicrobial: true, controlled: false)
    expect(matcher.flags_for([ "PARACETAMOL", "CODEÍNA" ])).to have_attributes(controlled: true, controlled_list: "A2")
    expect(matcher.flags_for([ "FLUOXETINA", "DIAZEPAM" ]).controlled_list).to eq("B1")
    expect(matcher.flags_for([ "AMOXICILINAS" ]).antimicrobial).to be(false) # palavra inteira
    expect(matcher.flags_for([ "LOSARTANA POTÁSSICA" ])).to eq(described_class::Flags.new(antimicrobial: false, controlled: false, controlled_list: nil))
  end

  it "varre texto livre por palavra inteira" do
    expect(matcher.scan("Diazepam 10mg 1 cp à noite").controlled).to be(true)
    expect(matcher.scan("amoxicilina 500 mg 8/8h").antimicrobial).to be(true)
    expect(matcher.scan("Chá de camomila").controlled).to be(false)
  end

  it "sem release ativa o matcher é vazio" do
    expect(described_class.matcher(nil)).to be_empty
  end
end
