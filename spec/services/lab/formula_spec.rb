require "rails_helper"

RSpec.describe Lab::Formula do
  it "compila e calcula Friedewald; recusa chave fora da lista e expressão mal formada" do
    rpn = described_class.compile("ct - hdl - tg / 5", allowed: %w[ct hdl tg])
    values = { "ct" => BigDecimal("200"), "hdl" => BigDecimal("50"), "tg" => BigDecimal("150") }
    expect(described_class.evaluate(rpn, values: values)).to eq(BigDecimal("120"))
    expect(described_class.evaluate(described_class.compile("(ct + hdl) * 2", allowed: %w[ct hdl]), values: values)).to eq(500)
    expect(described_class.evaluate(rpn, values: values.except("tg"))).to be_nil
    expect(described_class.evaluate(described_class.compile("ct / (hdl - hdl)", allowed: %w[ct hdl]), values: values)).to be_nil
    [ "ct - x", "ct +", "(ct", "ct)", "ct hdl", "", "ct; system('x')", "-ct", "ct ** 2", "a" * 201 ].each do |bad|
      expect(described_class.compile(bad, allowed: %w[ct hdl])).to be_nil, bad
    end
  end
end
