# spec/services/analytics/suppression_spec.rb
require "rails_helper"

# Contratos §0: Cell e Rate. Supressão depois de somar; zero continua zero.
RSpec.describe Analytics::Suppression do
  it "contagem de 1 a 4 vira { suppressed: true }; 0 e 5+ ficam" do
    expect([ 0, 1, 4, 5, 120 ].map { |n| described_class.cell(n) })
      .to eq([ 0, { suppressed: true }, { suppressed: true }, 5, 120 ])
  end

  it "taxa: nula com denominador 0, suprimida com numerador ou denominador pequenos, senão 1 casa" do
    expect(described_class.rate(0, 0)).to be_nil
    expect(described_class.rate(3, 200)).to eq(described_class::SUPPRESSED)
    expect(described_class.rate(3, 4)).to eq(described_class::SUPPRESSED)
    expect(described_class.rate(0, 3)).to eq(described_class::SUPPRESSED)
    expect(described_class.rate(0, 50)).to eq(0.0)
    expect(described_class.rate(10, 30)).to eq(33.3)
  end

  # Total do grupo (contratos §0, decisão de 2026-09-30): senão a parte oculta
  # sairia por subtração.
  it "total do grupo: oculto se qualquer parte (contagem crua ou célula já oculta) for oculta" do
    expect(described_class.group(13, [ 10, 3, 0 ])).to eq(described_class::SUPPRESSED)
    expect(described_class.group(20, [ 20, described_class::SUPPRESSED ])).to eq(described_class::SUPPRESSED)
    expect(described_class.group(15, [ 10, 5, 0 ])).to eq(15)
    expect(described_class.group(3, [ 0, 3 ])).to eq(described_class::SUPPRESSED)
    expect(described_class.group(0, [ 0, 0 ])).to eq(0)
  end

  it "taxa do grupo: oculta se qualquer parte do numerador ou do denominador for oculta; nula sem denominador" do
    expect(described_class.group_rate(20, 33, [ 20, 3, 10 ])).to eq(described_class::SUPPRESSED)
    expect(described_class.group_rate(20, 30, [ 20, 0, 10 ])).to eq(66.7)
    expect(described_class.group_rate(0, 0, [ 0, 0 ])).to be_nil
  end

  it "ordena suprimido e nulo como 0" do
    expect([ { suppressed: true }, nil, 7 ].map { |v| described_class.sort_value(v) }).to eq([ 0, 0, 7 ])
  end
end
