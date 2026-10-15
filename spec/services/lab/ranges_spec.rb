require "rails_helper"

# Divergência M5 do maintenance: idade obrigatória (0..43800 dias), low/high
# nulos = sem limite daquele lado, text para referência não numérica.
RSpec.describe Lab::Ranges do
  def parse(*ranges) = described_class.parse(ranges)

  it "normaliza e aceita sem limite de um lado" do
    result = parse({ "sex" => "female", "age_min_days" => 0, "age_max_days" => 43_800, "low" => "12,0", "high" => nil, "text" => nil },
                   { sex: "any", age_min_days: 6570, age_max_days: 43_800, low: nil, high: nil, text: "Negativo" })
    expect(result.payload[:ranges]).to eq([
      { "sex" => "female", "age_min_days" => 0, "age_max_days" => 43_800, "low" => 12.0, "high" => nil, "text" => nil },
      { "sex" => "any", "age_min_days" => 6570, "age_max_days" => 43_800, "low" => nil, "high" => nil, "text" => "Negativo" }
    ])
  end

  it "recusa sexo, idade e limites incoerentes" do
    base = { "sex" => "any", "age_min_days" => 0, "age_max_days" => 100, "low" => 1, "high" => 2, "text" => nil }
    [ base.merge("sex" => "M"), base.merge("age_min_days" => 101), base.merge("age_max_days" => 43_801),
      base.merge("age_min_days" => nil), base.merge("low" => 3), base.merge("low" => "abc"),
      base.merge("text" => "x" * 121) ].each do |bad|
      expect(parse(bad).reason).to eq(:invalid_reference_ranges), bad.inspect
    end
    expect(described_class.parse("nope").reason).to eq(:invalid_reference_ranges)
    expect(described_class.parse(Array.new(21) { base }).reason).to eq(:invalid_reference_ranges)
  end
end
