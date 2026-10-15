require "rails_helper"

RSpec.describe Lab::Analytes do
  let(:base) { LabHelpers::LIPIDS.map(&:dup) }

  it "normaliza e aceita calculado sobre numéricos não calculados" do
    result = described_class.parse(base)
    expect(result).to be_ok
    expect(result.payload[:analytes].last).to include("key" => "ldl", "formula" => "ct - hdl - tg / 5")
  end

  it "recusa o que não fecha" do
    { [ base.first.merge("key" => "CT") ] => :invalid_analytes,
      [ base.first, base.first ] => :invalid_analytes,
      [ base.first.merge("value_type" => "choice", "choices" => []) ] => :choices_required, # B29
      [ base.first.merge("entry_min" => 10, "entry_max" => 5) ] => :invalid_analytes,
      [ base.first.merge("decimals" => 5) ] => :invalid_analytes,
      [ base.first.merge("reference_ranges" => [ { "sex" => "x", "age_min_days" => 0, "age_max_days" => 1 } ]) ] => :invalid_reference_ranges,
      base[0..2] + [ base[3].merge("formula" => "ct - ldl") ] => :invalid_formula,
      [ base.first.merge("value_type" => "text", "formula" => "1 + 1") ] => :invalid_formula,
      [] => :invalid_analytes, "nope" => :invalid_analytes }.each do |raw, code|
      expect(described_class.parse(raw).reason).to eq(code), raw.inspect[0, 120]
    end
  end

  it "B29: lista de opções com os mesmos limites do catálogo-base (≤20, ≤60, sem vazio nem repetição)" do
    choice = base.first.merge("value_type" => "choice", "unit" => nil, "formula" => nil)
    expect(described_class.parse([ choice.merge("choices" => %w[Positivo Negativo]) ]).payload[:analytes].first["choices"]).to eq(%w[Positivo Negativo])
    [ (1..21).map { |i| "op#{i}" }, [ "a" * 61 ], [ "Positivo", " " ], %w[Positivo Positivo] ].each do |choices|
      expect(described_class.parse([ choice.merge("choices" => choices) ]).reason).to eq(:choices_required), choices.inspect[0, 60]
    end
  end
end
