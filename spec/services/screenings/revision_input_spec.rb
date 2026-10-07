# spec/services/screenings/revision_input_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.1, §3.3): queixa CIAP-2 obrigatória, sinais, cor final e
# justificativa quando a cor final difere da sugerida (recalculada aqui).
RSpec.describe Screenings::RevisionInput do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:citizen) { screening_citizen!(1) }

  def input(**over) = described_class.call(revision_params(**over), citizen: citizen)

  it "monta as colunas da revisão com a sugestão do servidor" do
    protocol = acolhimento!
    result = input(vitals: { "systolic" => "185", "diastolic" => "110" }, final_color: "red", complaint_note: "  cefaleia forte  ")
    expect(result).to be_ok
    expect(result.payload[:attrs]).to include(
      "ciap2_code" => "K86", "ciap2_release_id" => TerminologyRelease.active.find_by!(kind: "ciap2").id,
      "complaint_note" => "cefaleia forte", "systolic" => 185, "diastolic" => 110, "suggested_color" => "red",
      "final_color" => "red", "color_change_reason" => nil, "rule_protocol_definition_id" => protocol.id, "matched_rules" => [ 0 ]
    )
    expect(result.payload[:alerts]).to eq(%w[systolic_high diastolic_high])
  end

  it "cor diferente da sugerida exige justificativa de 10+; sem sugestão a cor é livre e a justificativa some" do
    acolhimento!
    red = { "systolic" => 185, "diastolic" => 110 }
    expect(input(vitals: red, final_color: "yellow").reason).to eq(:color_change_reason_required)
    expect(input(vitals: red, final_color: "yellow", color_change_reason: "curta").reason).to eq(:color_change_reason_required)
    ok = input(vitals: red, final_color: "yellow", color_change_reason: "PA medida após esforço, repetida 150/95")
    expect(ok.payload[:attrs]["color_change_reason"]).to eq("PA medida após esforço, repetida 150/95")
    free = input(vitals: { "systolic" => 120, "diastolic" => 80 }, final_color: "blue", color_change_reason: "qualquer coisa aqui")
    expect(free.payload[:attrs].values_at("suggested_color", "final_color", "color_change_reason")).to eq([ nil, "blue", nil ])
  end

  it "justificativa acima de 500 → note_too_long com o campo (contratos §9)" do
    acolhimento!
    result = input(vitals: { "systolic" => 185, "diastolic" => 110 }, final_color: "yellow",
                   color_change_reason: "x" * 501)
    expect([ result.reason, result.details[:field] ]).to eq([ :note_too_long, "color_change_reason" ])
  end

  it "reaproveita a normalização dos sinais (vírgula decimal, vazio = não medido)" do
    result = input(vitals: { "systolic" => "", "diastolic" => nil, "temperature_c" => "37,85", "weight_kg" => "70",
                             "height_cm" => "175" })
    expect(result).to be_ok
    expect(result.payload[:attrs]).to include("systolic" => nil, "temperature_c" => BigDecimal("37.9"))
    expect(result.payload[:alerts]).to eq(%w[temperature_high])
    expect(result.payload[:bmi]).to eq(22.9)
  end

  {
    { ciap2_code: "Z99" } => [ :invalid_ciap2, nil ],
    { ciap2_code: nil } => [ :invalid_ciap2, nil ],
    { vitals: { "systolic" => 120 } } => [ :bp_incomplete, nil ],
    { vitals: { "spo2" => 30 } } => [ :implausible_vital, "spo2" ],
    { final_color: "orange" } => [ :invalid_color, nil ],
    { final_color: nil } => [ :invalid_color, nil ],
    { complaint_note: "x" * 501 } => [ :note_too_long, "complaint_note" ]
  }.each do |over, (reason, field)|
    it("#{over.inspect} → #{reason}") do
      result = input(**over)
      expect([ result.reason, result.details[:field] ]).to eq([ reason, field ])
    end
  end
end
