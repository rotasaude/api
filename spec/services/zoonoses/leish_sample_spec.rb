require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, Q18, Q32): o tamanho do
# inquérito de leishmaniose pela tabela de 2% da Task 1 (cada linha leva o
# limite SUPERIOR da faixa; a primeira, `min_population: 500`). Abaixo do
# limite inferior da primeira linha, censo; acima da última, a amostra da
# última; em todo tipo, target ≤ dog_population. O foco é a própria população,
# com o aviso below_focus_min (decisão do coordenador sobre o §6). Sugestão de
# população: os cães ativos, ou quarteirões × dogs_per_block sem cão (Q18).
RSpec.describe Zoonoses::LeishSample, type: :model do
  let(:parameters) { Zoonoses::Parameters::Snapshot.new(version: 0, values: Zoonoses::Parameters.defaults) }

  def target(kind, population, params: parameters) = described_class.target(kind: kind, dog_population: population, parameters: params)

  it "amostra pela tabela da Task 1: 600 cães → 334; 500 → 300; a linha é o limite superior da faixa" do
    expect(target("sample", 600)).to eq(334)
    expect(target("sample", 500)).to eq(300)
    expect(target("sample", 599)).to eq(300)
    expect(target("sample", 1000)).to eq(430)
  end

  it "população entre duas linhas → a de cima" do
    expect(target("sample", 650)).to eq(334)
    expect(target("sample", 700)).to eq(363)
    expect(target("sample", 950)).to eq(410)
  end

  it "acima da última linha → a amostra da última (Q18)" do
    expect(target("sample", 1001)).to eq(430)
    expect(target("sample", 25_000)).to eq(430)
  end

  it "Q32: abaixo do min_population da primeira linha → todos os cães (100 → 100; 499 → 499)" do
    expect(target("sample", 100)).to eq(100)
    expect(target("sample", 499)).to eq(499)
  end

  it "Q32: o limite inferior é lido da tabela, não do código" do
    table = [ { "population" => 200, "sample" => 150, "min_population" => 100 }, { "population" => 400, "sample" => 250 } ]
    params = Zoonoses::Parameters::Snapshot.new(version: 3, values: Zoonoses::Parameters.defaults.merge("leish_sample_table" => table))
    expect(target("sample", 99, params: params)).to eq(99)
    expect(target("sample", 120, params: params)).to eq(120) # a amostra (150) passaria da população
    expect(target("sample", 180, params: params)).to eq(150)
    expect(target("sample", 600, params: params)).to eq(250)

    without_floor = Zoonoses::Parameters::Snapshot.new(version: 4, values: Zoonoses::Parameters.defaults
                                                                     .merge("leish_sample_table" => [ { "population" => 50, "sample" => 40 } ]))
    expect(target("sample", 30, params: without_floor)).to eq(30)
    expect(target("sample", 45, params: without_floor)).to eq(40)
  end

  it "census 250 → 250" do
    expect(target("census", 250)).to eq(250)
    expect(target("census", 5000)).to eq(5000)
  end

  it "focus 40 → 40 com below_focus_min; 180 → 180 sem (target nunca passa da população, Q32)" do
    expect(target("focus", 40)).to eq(40)
    expect(described_class.below_focus_min?(kind: "focus", dog_population: 40, parameters: parameters)).to be(true)
    expect(target("focus", 180)).to eq(180)
    expect(described_class.below_focus_min?(kind: "focus", dog_population: 180, parameters: parameters)).to be(false)
    expect(described_class.below_focus_min?(kind: "focus", dog_population: 100, parameters: parameters)).to be(false)
    expect(described_class.below_focus_min?(kind: "sample", dog_population: 40, parameters: parameters)).to be(false)
  end

  it "tipo desconhecido → ArgumentError" do
    expect { target("sorteio", 10) }.to raise_error(ArgumentError)
  end

  it "sugestão com 0 cães e 12 quarteirões → 192; com 40 cães → 40 (Q18)" do
    expect(described_class.suggested_population(active_dogs: 0, blocks_count: 12, parameters: parameters)).to eq(192)
    expect(described_class.suggested_population(active_dogs: 40, blocks_count: 12, parameters: parameters)).to eq(40)
  end
end
