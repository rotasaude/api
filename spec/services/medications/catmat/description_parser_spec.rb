require "rails_helper"

# ADR 0033 (spec §3, §9): o analisador contra amostras REAIS do CATMAT. O que
# a regra não entende vai a revisão com o motivo — nunca um palpite.
RSpec.describe Medications::Catmat::DescriptionParser do
  samples = YAML.load_file(Rails.root.join("spec/fixtures/medications/catmat/samples.yml"), symbolize_names: true)

  samples.each do |sample|
    it "#{sample[:code]}: #{sample[:description].strip}" do
      parsed = described_class.call(sample[:pdm], sample[:description])
      expect(parsed.to_h.compact).to eq(sample[:expected])
    end
  end

  it "revisão nunca traz força, forma nem unidade" do
    parsed = described_class.call("X", "X, ESCALA: 30 CH")
    expect(parsed).to have_attributes(parse_status: "review", strength: nil, dosage_form: nil, unit: nil)
    expect(parsed.ok?).to be(false)
  end

  it "descrição vazia ou sem PDM não levanta" do
    expect(described_class.call(nil, "").parse_status).to eq("review")
    expect(described_class.call("", "AMOXICILINA, DOSAGEM: 500 MG").active_ingredient).to eq("AMOXICILINA")
  end
end
