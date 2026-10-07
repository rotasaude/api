require "rails_helper"

# ADR 0030 (spec §3.1): limite de plausibilidade recusa; faixa de alerta
# destaca; IMC na leitura. Review Focus 2: entrada da tela nas bordas.
RSpec.describe Screenings::VitalSigns do
  def parse(raw) = described_class.parse(raw)

  describe "valores aceitos" do
    {
      {} => {},
      nil => {},
      { "systolic" => 120, "diastolic" => 80 } => { "systolic" => 120, "diastolic" => 80 },
      { systolic: "120", diastolic: "80" } => { "systolic" => 120, "diastolic" => 80 },
      { "temperature_c" => "37,85" } => { "temperature_c" => BigDecimal("37.9") },
      { "temperature_c" => 36.5 } => { "temperature_c" => BigDecimal("36.5") },
      { "weight_kg" => "72.456" } => { "weight_kg" => BigDecimal("72.46") },
      { "spo2" => "", "heart_rate" => " " } => {},
      { "pain_score" => 0 } => { "pain_score" => 0 },
      { "systolic" => "120.0", "diastolic" => 80 } => { "systolic" => 120, "diastolic" => 80 },
      { "capillary_glucose" => 95, "glucose_moment" => "fasting" } => { "capillary_glucose" => 95, "glucose_moment" => "fasting" },
      { "systolic" => 300, "diastolic" => 200, "heart_rate" => 20, "respiratory_rate" => 80, "spo2" => 50,
        "temperature_c" => 45, "weight_kg" => "0.5", "height_cm" => 250, "capillary_glucose" => 800,
        "glucose_moment" => "random", "pain_score" => 10 } =>
        { "systolic" => 300, "diastolic" => 200, "heart_rate" => 20, "respiratory_rate" => 80, "spo2" => 50,
          "temperature_c" => BigDecimal("45"), "weight_kg" => BigDecimal("0.5"), "height_cm" => 250,
          "capillary_glucose" => 800, "glucose_moment" => "random", "pain_score" => 10 },
      { "bmi" => 99, "outro" => 1 } => {}
    }.each do |raw, values|
      it("#{raw.inspect} → #{values.inspect}") do
        result = parse(raw)
        expect(result).to be_ok
        expect(result.payload[:values]).to eq(values)
      end
    end
  end

  describe "recusas" do
    {
      { "systolic" => 120 } => [ :bp_incomplete, nil ],
      { "diastolic" => 80 } => [ :bp_incomplete, nil ],
      { "systolic" => 301, "diastolic" => 80 } => [ :implausible_vital, "systolic" ],
      { "systolic" => 49, "diastolic" => 30 } => [ :implausible_vital, "systolic" ],
      { "systolic" => 120, "diastolic" => 120 } => [ :implausible_vital, "diastolic" ],
      { "systolic" => "120.5", "diastolic" => 80 } => [ :implausible_vital, "systolic" ],
      { "systolic" => "cento e vinte", "diastolic" => 80 } => [ :implausible_vital, "systolic" ],
      { "systolic" => 0, "diastolic" => 0 } => [ :implausible_vital, "systolic" ],
      { "heart_rate" => 251 } => [ :implausible_vital, "heart_rate" ],
      { "respiratory_rate" => 3 } => [ :implausible_vital, "respiratory_rate" ],
      { "temperature_c" => "29,9" } => [ :implausible_vital, "temperature_c" ],
      { "spo2" => 101 } => [ :implausible_vital, "spo2" ],
      { "capillary_glucose" => 801, "glucose_moment" => "fasting" } => [ :implausible_vital, "capillary_glucose" ],
      { "capillary_glucose" => 120 } => [ :implausible_vital, "glucose_moment" ],
      { "glucose_moment" => "fasting" } => [ :implausible_vital, "capillary_glucose" ],
      { "capillary_glucose" => 120, "glucose_moment" => "noite" } => [ :implausible_vital, "glucose_moment" ],
      { "weight_kg" => "0.4" } => [ :implausible_vital, "weight_kg" ],
      { "height_cm" => 251 } => [ :implausible_vital, "height_cm" ],
      { "pain_score" => -1 } => [ :implausible_vital, "pain_score" ],
      { "spo2" => [ 98 ] } => [ :implausible_vital, "spo2" ],
      "lixo" => [ :implausible_vital, "vitals" ],
      [ 1, 2 ] => [ :implausible_vital, "vitals" ]
    }.each do |raw, (reason, field)|
      it("#{raw.inspect} → #{reason} #{field}") do
        result = parse(raw)
        expect(result).to be_failure
        expect(result.reason).to eq(reason)
        expect(result.details[:field]).to eq(field)
      end
    end
  end

  describe "alertas" do
    {
      { "systolic" => 139, "diastolic" => 89 } => [],
      { "systolic" => 140, "diastolic" => 90 } => %w[systolic_high diastolic_high],
      { "heart_rate" => 101 } => %w[heart_rate_high],
      { "heart_rate" => 49 } => %w[heart_rate_low],
      { "respiratory_rate" => 25 } => %w[respiratory_rate_high],
      { "temperature_c" => "37.7" } => [],
      { "temperature_c" => "37.8" } => %w[temperature_high],
      { "spo2" => 95 } => [],
      { "spo2" => 94 } => %w[spo2_low],
      { "capillary_glucose" => 69, "glucose_moment" => "random" } => %w[glucose_low],
      { "capillary_glucose" => 200, "glucose_moment" => "postprandial" } => %w[glucose_high],
      { "pain_score" => 7 } => %w[pain_severe]
    }.each do |raw, alerts|
      it("#{raw.inspect} → #{alerts.inspect}") { expect(parse(raw).payload[:alerts]).to eq(alerts) }
    end
  end

  it "IMC com peso e altura, nil sem um deles; json devolve número" do
    result = parse("weight_kg" => "80", "height_cm" => 175)
    expect(result.payload[:bmi]).to eq(26.1)
    expect(parse("weight_kg" => 80).payload[:bmi]).to be_nil
    expect(described_class.json(result.payload[:values])).to eq("weight_kg" => 80.0, "height_cm" => 175)
  end
end
