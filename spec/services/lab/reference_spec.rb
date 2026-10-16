require "rails_helper"

# Review Focus 3: faixa do sexo e da idade NA DATA DA COLETA, limites
# inclusivos; sem nascimento só a faixa sem restrição de idade; crítico vence.
RSpec.describe Lab::Reference do
  let(:analyte) do
    { "key" => "hb", "value_type" => "numeric", "unit" => "g/dL", "critical_low" => 7.0, "critical_high" => 20.0,
      "reference_ranges" => [
        { "sex" => "female", "age_min_days" => 0, "age_max_days" => 4380, "low" => 11.5, "high" => 15.5, "text" => nil },
        { "sex" => "female", "age_min_days" => 4381, "age_max_days" => 43_800, "low" => 12.0, "high" => 15.5, "text" => nil },
        { "sex" => "any", "age_min_days" => 0, "age_max_days" => 43_800, "low" => 12.0, "high" => 17.5, "text" => nil } ] }
  end

  it "idade na borda, faixa any de reserva, crítico igual ao limite" do
    expect(described_class.range_for(analyte, sex: "female", age_days: 4380)["low"]).to eq(11.5)
    expect(described_class.range_for(analyte, sex: "female", age_days: 4381)["low"]).to eq(12.0)
    expect(described_class.range_for(analyte, sex: "male", age_days: 10_000)["high"]).to eq(17.5)
    expect(described_class.range_for(analyte, sex: "female", age_days: nil)["sex"]).to eq("any")
    expect(described_class.flag(analyte, BigDecimal("11.9"), sex: "female", age_days: 5000)).to eq("low")
    expect(described_class.flag(analyte, BigDecimal("12.0"), sex: "female", age_days: 5000)).to eq("normal")
    expect(described_class.flag(analyte, BigDecimal("15.6"), sex: "female", age_days: 5000)).to eq("high")
    # B27: crítico INCLUSIVO (= critical_low/high é crítico); = low/high da faixa é normal.
    expect(described_class.flag(analyte, BigDecimal("7.0"), sex: "female", age_days: 5000)).to eq("critical_low")
    expect(described_class.flag(analyte, BigDecimal("7.1"), sex: "female", age_days: 5000)).to eq("low")
    expect(described_class.flag(analyte, BigDecimal("20.0"), sex: "male", age_days: 5000)).to eq("critical_high")
    expect(described_class.flag(analyte, BigDecimal("19.9"), sex: "male", age_days: 5000)).to eq("high")
    expect(described_class.flag(analyte, BigDecimal("15.5"), sex: "female", age_days: 5000)).to eq("normal")
    expect(described_class.flag(analyte, BigDecimal("6.9"), sex: "female", age_days: 5000)).to eq("critical_low")
    expect(described_class.flag(analyte, BigDecimal("20.1"), sex: "male", age_days: 5000)).to eq("critical_high")
    expect(described_class.text(analyte, described_class.range_for(analyte, sex: "female", age_days: 5000))).to eq("12,0 a 15,5 g/dL")
    expect(described_class.text({ "unit" => "mg/dL", "decimals" => 0 }, { "low" => nil, "high" => 190.0, "text" => nil })).to eq("até 190 mg/dL")
    expect(described_class.flag({ "value_type" => "text" }, nil, sex: "male", age_days: 1)).to eq("normal")
  end

  it "sem nascimento, faixa que exige idade não serve" do
    only_adult = analyte.merge("reference_ranges" => [ analyte["reference_ranges"][1] ])
    expect(described_class.range_for(only_adult, sex: "female", age_days: nil)).to be_nil
    expect(described_class.flag(only_adult, BigDecimal("10"), sex: "female", age_days: nil)).to eq("normal")
    # crítico vale mesmo sem faixa aplicável (1 < critical_low 7)
    expect(described_class.flag(only_adult, BigDecimal("1"), sex: "female", age_days: nil)).to eq("critical_low")
  end
end
