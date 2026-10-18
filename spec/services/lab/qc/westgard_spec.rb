require "rails_helper"

# Spec §5.3 e §10: cada regra com série conhecida (dispara e não dispara);
# R-4s e 2-2s também entre níveis da mesma corrida; limites estritos
# (Desvio 5); regra desligada não dispara; rules_fired em ordem fixa.
RSpec.describe Lab::Qc::Westgard do
  def ev(z, series: [], peers: [], enabled: LabQcRule::RULES)
    described_class.evaluate(z: BigDecimal(z.to_s), series: series.map { |v| BigDecimal(v.to_s) },
                             peers: peers.map { |v| BigDecimal(v.to_s) }, enabled: enabled)
  end

  def fired(...) = ev(...).rules_fired

  it "1-2s: aviso acima de 2 dp; 2,0 exato não dispara" do
    expect(ev(2.1)).to have_attributes(rules_fired: [ "1_2s" ], outcome: "warning")
    expect(ev(-2.5)).to have_attributes(rules_fired: [ "1_2s" ], outcome: "warning")
    expect(ev(2.0)).to have_attributes(rules_fired: [], outcome: "ok")
    expect(ev(0)).to have_attributes(rules_fired: [], outcome: "ok")
  end

  it "1-3s: reprova acima de 3 dp; 3,0 exato só avisa" do
    expect(ev(3.1)).to have_attributes(rules_fired: %w[1_2s 1_3s], outcome: "reject")
    expect(ev(-3.2)).to have_attributes(rules_fired: %w[1_2s 1_3s], outcome: "reject")
    expect(ev(3.0)).to have_attributes(rules_fired: [ "1_2s" ], outcome: "warning")
  end

  it "2-2s no mesmo nível: dois consecutivos além de 2 dp do mesmo lado" do
    expect(ev(2.3, series: [ 0.1, 2.2 ])).to have_attributes(rules_fired: %w[1_2s 2_2s], outcome: "reject")
    expect(fired(-2.4, series: [ -2.1 ])).to eq(%w[1_2s 2_2s])
    expect(fired(2.3, series: [ 2.2, 0.1 ])).to eq([ "1_2s" ]) # não consecutivo
    expect(fired(2.3, series: [ -2.2 ])).to eq([ "1_2s" ])     # lados opostos
    expect(fired(2.3, series: [ 2.0 ])).to eq([ "1_2s" ])      # 2,0 não passa de 2
  end

  it "2-2s entre níveis na mesma corrida" do
    expect(ev(2.4, peers: [ 2.6 ])).to have_attributes(rules_fired: %w[1_2s 2_2s], outcome: "reject")
    expect(fired(2.4, peers: [ 1.9 ])).to eq([ "1_2s" ])
  end

  it "R-4s entre níveis: um acima de +2 e outro abaixo de −2 na mesma corrida" do
    expect(ev(2.1, peers: [ -2.2 ])).to have_attributes(rules_fired: %w[1_2s R_4s], outcome: "reject")
    expect(fired(-2.3, peers: [ 2.05 ])).to eq(%w[1_2s R_4s])
    expect(fired(2.1, peers: [ -1.9 ])).to eq([ "1_2s" ]) # amplitude 4,0 sem passar de −2
    expect(fired(1.5, peers: [ -2.6 ])).to eq([])          # o atual não passa de +2
    expect(fired(2.5, series: [ -2.5 ])).to eq([ "1_2s" ]) # R-4s não olha a série
  end

  it "4-1s: quatro consecutivos além de 1 dp do mesmo lado" do
    expect(ev(1.2, series: [ 1.1, 1.5, 1.3 ])).to have_attributes(rules_fired: [ "4_1s" ], outcome: "reject")
    expect(fired(-1.4, series: [ 0.2, -1.1, -1.2, -1.05 ])).to eq([ "4_1s" ])
    expect(fired(1.2, series: [ 1.1, 0.9, 1.3 ])).to eq([])
    expect(fired(1.2, series: [ 1.5, 1.3 ])).to eq([]) # só três valores
    expect(fired(1.2, series: [ 1.0, 1.5, 1.3 ])).to eq([]) # 1,0 não passa de 1
  end

  it "10x: dez consecutivos do mesmo lado da média" do
    expect(ev(0.3, series: [ 0.1 ] * 9)).to have_attributes(rules_fired: [ "10x" ], outcome: "reject")
    expect(fired(-0.2, series: [ -0.5 ] * 9)).to eq([ "10x" ])
    expect(fired(0.3, series: [ 0.1 ] * 8 + [ 0.0 ])).to eq([]) # zero quebra a sequência
    expect(fired(0.3, series: [ 0.1 ] * 8)).to eq([])           # só nove valores
    expect(fired(-0.3, series: [ 0.1 ] * 9)).to eq([])
  end

  it "regra desligada não dispara; ordem fixa" do
    expect(ev(3.5, enabled: LabQcRule::RULES - [ "1_3s" ])).to have_attributes(rules_fired: [ "1_2s" ], outcome: "warning")
    expect(ev(3.5, enabled: [])).to have_attributes(rules_fired: [], outcome: "ok")
    expect(fired(3.5, series: [ 2.5 ], peers: [ -2.5 ])).to eq(%w[1_2s 1_3s 2_2s R_4s])
  end
end
