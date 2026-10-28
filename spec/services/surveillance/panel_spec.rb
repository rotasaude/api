require "rails_helper"

# Módulo 25, Task 16 (contrato §8, K7; Desvios 9 e 10): o painel por bairro ×
# semana epidemiológica, com supressão de 1–4 e o sinal de aumento atípico.
RSpec.describe Surveillance::Panel do
  before { surveillance_city! }
  let(:week) { Surveillance::EpiWeek.parse("2026-40") }

  def cases!(count, neighborhood:, on:, **over)
    count.times { panel_case!(neighborhood: neighborhood, symptoms_on: on, suspected_on: on + 1, **over) }
  end

  def week_start(number) = Surveillance::EpiWeek.new(year: 2026, week: number).starts_on
  def hood(name) = Neighborhood.create!(name: name, source: "manual")
  def row_for(out, name) = out[:rows].find { |r| r[:neighborhood][:name] == name }

  it "suprime 1–4 (bairro e não informado), sinal só em célula visível acima do dobro da média das 4 anteriores" do
    centro = Neighborhood.create!(name: "Centro", source: "manual")
    boqueirao = Neighborhood.create!(name: "Boqueirão", source: "manual")
    (36..39).each { |w| cases!(2, neighborhood: centro, on: Surveillance::EpiWeek.new(year: 2026, week: w).starts_on) }
    cases!(6, neighborhood: centro, on: week.starts_on)
    cases!(3, neighborhood: boqueirao, on: week.starts_on)
    cases!(1, neighborhood: nil, on: week.starts_on)
    out = described_class.call(from: week, to: week)
    rows = out[:rows].to_h { |r| [ r[:neighborhood][:name], r ] }
    expect(out[:weeks]).to eq(%w[2026-40])
    expect(rows["Centro"]).to include(counts: [ 6 ], signal: [ true ])
    expect(rows["Boqueirão"]).to include(counts: [ nil ], signal: [ false ])
    expect(rows["Não informado"]).to include(counts: [ nil ], signal: [ false ])
    expect(out[:rows].last[:neighborhood]).to eq(id: nil, name: "Não informado")
    expect(out[:suppressed]).to be(true)
  end

  it "semana pelos primeiros sintomas (virada de ano); possible, dismissed e descartada fora" do
    centro = Neighborhood.create!(name: "Centro", source: "manual")
    cases!(5, neighborhood: centro, on: Date.new(2026, 1, 3))
    panel_case!(neighborhood: centro, symptoms_on: Date.new(2026, 1, 3), suspected_on: Date.new(2026, 1, 5), status: "possible")
    panel_case!(neighborhood: centro, symptoms_on: Date.new(2026, 1, 3), suspected_on: Date.new(2026, 1, 5), status: "dismissed")
    panel_case!(neighborhood: centro, symptoms_on: Date.new(2026, 1, 3), suspected_on: Date.new(2026, 1, 5), status: "closed",
                classification: "discarded")
    out = described_class.call(from: Surveillance::EpiWeek.parse("2025-53"), to: Surveillance::EpiWeek.parse("2026-01"))
    expect(out[:rows].first[:counts]).to eq([ 5, 0 ])
  end

  it "sem sintomas informados conta pela semana da suspeita; fechada confirmada e investigando contam" do
    centro = hood("Centro")
    panel_case!(neighborhood: centro, symptoms_on: nil, suspected_on: week.starts_on + 2)
    cases!(2, neighborhood: centro, on: week.starts_on, status: "closed", classification: "confirmed")
    cases!(2, neighborhood: centro, on: week.starts_on, status: "investigating")
    out = described_class.call(from: week, to: week)
    expect(out[:rows].first[:counts]).to eq([ 5 ])
  end

  it "zero é zero (não suprimido); só entram bairros com caso no intervalo; as 4 semanas de base não são devolvidas" do
    centro = hood("Centro")
    so_na_base = hood("Só na base")
    cases!(1, neighborhood: so_na_base, on: week_start(38))
    cases!(5, neighborhood: centro, on: week_start(41))
    out = described_class.call(from: week, to: Surveillance::EpiWeek.parse("2026-41"))
    expect(out[:weeks]).to eq(%w[2026-40 2026-41])
    expect(out[:rows].map { |r| r[:neighborhood][:name] }).to eq([ "Centro" ])
    expect(out[:rows].first).to include(counts: [ 0, 5 ], signal: [ false, true ])
  end

  it "o sinal exige 5 casos e mais que o dobro da média das 4 anteriores (K14: a suprimida entra como 2,5)" do
    centro = hood("Centro")
    [ 36, 37, 38, 39 ].each { |w| cases!(1, neighborhood: centro, on: week_start(w)) }
    cases!(4, neighborhood: centro, on: week_start(40))
    cases!(6, neighborhood: centro, on: week_start(41))
    cases!(5, neighborhood: centro, on: week_start(42))
    out = described_class.call(from: Surveillance::EpiWeek.parse("2026-36"), to: Surveillance::EpiWeek.parse("2026-42"))
    # 36–40 suprimidas (nil, sem sinal mesmo a de 4 acima do dobro da base crua).
    # 41 = 6 > 2 × média(2,5 ×4) = 5; 42 = 5 não passa de 2 × média(2,5 ×3 e 6) = 6,75.
    expect(out[:rows].first).to include(counts: [ nil, nil, nil, nil, nil, 6, 5 ],
                                        signal: [ false, false, false, false, false, true, false ])
  end

  it "K14: o painel não muda com o valor da célula suprimida da base (1, 2, 3 ou 4), nem a semana fora do painel" do
    # Um bairro por valor de x, no mesmo banco: a saída de cada linha tem de ser igual.
    (1..4).each do |x|
      bairro = hood("Bairro #{x}")
      # Base visível somando 10 (5, 5, 0) e uma célula suprimida x; a semana do painel tem 6 casos.
      cases!(5, neighborhood: bairro, on: week_start(36))
      cases!(x, neighborhood: bairro, on: week_start(37))
      cases!(5, neighborhood: bairro, on: week_start(38))
      cases!(6, neighborhood: bairro, on: week_start(40))
    end
    out = described_class.call(from: week, to: week)
    outputs = out[:rows].map { |r| r.except(:neighborhood) }
    expect(out[:rows].size).to eq(4)
    expect(outputs.first).to eq(counts: [ 6 ], signal: [ false ])
    expect(outputs.uniq.size).to eq(1)
  end

  it "panel_case! recusa status desconhecido e classification fora de closed/entered" do
    args = { neighborhood: nil, symptoms_on: week.starts_on, suspected_on: week.starts_on }
    expect { panel_case!(**args, status: "closeed") }.to raise_error(ArgumentError, /unknown status/)
    expect { panel_case!(**args, status: "notified", classification: "confirmed") }.to raise_error(ArgumentError, /classification/)
  end

  it "closed (inconclusiva) e entered contam; closed descartada fica fora" do
    centro = hood("Centro")
    cases!(2, neighborhood: centro, on: week.starts_on, status: "closed", classification: "inconclusive")
    cases!(2, neighborhood: centro, on: week.starts_on, status: "entered")
    cases!(1, neighborhood: centro, on: week.starts_on, status: "entered", classification: "confirmed")
    cases!(3, neighborhood: centro, on: week.starts_on, status: "closed", classification: "discarded")
    expect(described_class.call(from: week, to: week).dig(:rows, 0, :counts)).to eq([ 5 ])
  end

  it "5 casos sem passar do dobro da média não dão sinal" do
    centro = hood("Centro")
    (36..39).each { |w| cases!(3, neighborhood: centro, on: week_start(w)) }
    cases!(5, neighborhood: centro, on: week_start(40))
    out = described_class.call(from: week, to: week)
    expect(out[:rows].first).to include(counts: [ 5 ], signal: [ false ])
  end

  it "ordena os bairros por nome sem acento nem caixa, e 'não informado' por último; 5 ou mais sem bairro aparecem" do
    cases!(5, neighborhood: hood("água verde"), on: week.starts_on)
    cases!(5, neighborhood: hood("Batel"), on: week.starts_on)
    cases!(5, neighborhood: hood("Abranches"), on: week.starts_on)
    cases!(5, neighborhood: nil, on: week.starts_on)
    out = described_class.call(from: week, to: week)
    expect(out[:rows].map { |r| r[:neighborhood][:name] }).to eq([ "Abranches", "água verde", "Batel", "Não informado" ])
    expect(out[:rows].last).to include(neighborhood: { id: nil, name: "Não informado" }, counts: [ 5 ])
  end

  it "filtra pela doença" do
    centro = hood("Centro")
    cases!(5, neighborhood: centro, on: week.starts_on)
    cases!(5, neighborhood: centro, on: week.starts_on, disease_code: "tuberculose")
    expect(described_class.call(from: week, to: week, disease: "dengue")[:rows].first[:counts]).to eq([ 5 ])
    expect(described_class.call(from: week, to: week)[:rows].first[:counts]).to eq([ 10 ])
  end

  it "não traz total em lugar nenhum e nenhum dado de pessoa" do
    cases!(5, neighborhood: hood("Centro"), on: week.starts_on)
    out = described_class.call(from: week, to: week)
    expect(out.keys).to eq(%i[weeks rows suppressed])
    expect(out[:rows].first.keys).to eq(%i[neighborhood counts signal])
    expect(out[:rows].first[:neighborhood].keys).to eq(%i[id name])
  end
end
