require "rails_helper"

# ADR 0030: as variáveis da escuta entram no contexto plano como texto;
# sinal ausente não entra (condição falsa).
RSpec.describe Protocols::ConditionContext do
  it "monta vitals.* e complaint.ciap2, sem nil, e reserva os prefixos" do
    context = described_class.build(vitals: { systolic: 185, temperature_c: BigDecimal("38.5"), spo2: nil, bmi: 31.2 },
                                    complaint: { ciap2: "K86" }, profile: { age: 61, sex: "female" })
    expect(context).to eq("vitals.systolic" => "185", "vitals.temperature_c" => "38.5", "vitals.bmi" => "31.2",
                          "complaint.ciap2" => "K86", "profile.age" => "61", "profile.sex" => "female")
    expect(described_class.reserved?("vitals.systolic")).to be(true)
    expect(described_class.reserved?("complaint.ciap2")).to be(true)
    expect(Protocols::Condition.eval({ "gte" => ["vitals.systolic", 180] }, context)).to be(true)
    expect(Protocols::Condition.eval({ "lt" => ["vitals.spo2", 90] }, context)).to be(false)
  end

  it "ignora campo desconhecido de vitals" do
    expect(described_class.build(vitals: { "pressao" => 1 })).to eq({})
  end
end
