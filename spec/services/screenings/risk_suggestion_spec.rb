# spec/services/screenings/risk_suggestion_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.3): vale a mais grave que casar (red > yellow > green >
# blue); regra com sinal não medido não casa (Review Focus 3).
RSpec.describe Screenings::RiskSuggestion do
  let(:rules) do
    [ { "when" => { "any" => [ { "gte" => ["vitals.systolic", 180] }, { "lt" => ["vitals.spo2", 90] } ] }, "color" => "red" },
      { "when" => { "gte" => ["vitals.temperature_c", 39] }, "color" => "yellow" },
      { "when" => { "eq" => ["complaint.ciap2", "R05"] }, "color" => "green" },
      { "when" => { "all" => [ { "gte" => ["profile.age", 60] }, { "gte" => ["vitals.bmi", 35] } ] }, "color" => "yellow" },
      { "when" => { "eq" => ["complaint.ciap2", "A97"] }, "color" => "blue" } ]
  end

  def suggest(vitals: {}, bmi: nil, ciap2: nil, age: 40, sex: "female", list: rules)
    described_class.call({ vitals: vitals, bmi: bmi, ciap2_code: ciap2 }, { age: age, sex: sex }, rules: list)
  end

  {
    "PA 185/110 → red" => [ { vitals: { "systolic" => 185, "diastolic" => 110 } }, "red", [ 0 ] ],
    "SpO2 88 com febre 39,5 → red (a mais grave)" =>
      [ { vitals: { "spo2" => 88, "temperature_c" => BigDecimal("39.5") } }, "red", [ 0, 1 ] ],
    "febre 39 e tosse → yellow" => [ { vitals: { "temperature_c" => BigDecimal("39") }, ciap2: "R05" }, "yellow", [ 1, 2 ] ],
    "tosse sem sinais → green" => [ { ciap2: "R05" }, "green", [ 2 ] ],
    "idosa com IMC 36 → yellow" => [ { bmi: 36.0, age: 61 }, "yellow", [ 3 ] ],
    "A97 → blue" => [ { ciap2: "A97" }, "blue", [ 4 ] ],
    "nada casa → sem sugestão" => [ { vitals: { "systolic" => 120, "diastolic" => 80 }, ciap2: "K86" }, nil, [] ],
    "SpO2 não medida não casa lt" => [ { vitals: {} }, nil, [] ],
    "sem regras → sem sugestão" => [ { ciap2: "R05", list: [] }, nil, [] ]
  }.each do |label, (input, color, matched)|
    it(label) { expect(suggest(**input)).to eq(color: color, matched: matched) }
  end

  it "regra malformada não casa nem levanta" do
    expect(suggest(ciap2: "R05", list: [ "x", { "when" => nil, "color" => "red" }, { "color" => "red" } ]))
      .to eq(color: nil, matched: [])
  end
end
