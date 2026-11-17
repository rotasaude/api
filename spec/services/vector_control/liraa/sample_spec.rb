require "rails_helper"

# Módulo 35a (contrato §7; Q16, Q17): faixas, tamanho da amostra e passos do
# LIRAa com o padrão de fábrica (config/vector_control/defaults.yml).
RSpec.describe VectorControl::Liraa::Sample, type: :model do
  let(:parameters) { VectorControl::Parameters.defaults }

  def plan(mode, n, b = 100, **over) = described_class.plan(mode: mode, households_count: n, blocks_count: b, parameters: parameters.merge(over.stringify_keys))
  def numbers(result) = result.to_h.slice(:n, :h, :b, :k, :interval)

  describe "standard (8.100 ≤ N ≤ 12.000)" do
    it "faixa" do
      expect(plan("standard", 8099)).to eq(:out_of_range)
      expect(plan("standard", 12_001)).to eq(:out_of_range)
    end

    it "8.100 com 100 quarteirões → n 427, h 17, b 26, k 3, intervalo 5" do
      # n = ⌈450 ÷ (1 + 450 ÷ 8100)⌉ = ⌈426,3⌉ = 427; h = ⌈0,2 · 8100 ÷ 100⌉ = ⌈16,2⌉ = 17;
      # b = ⌈427 ÷ 17⌉ = ⌈25,1⌉ = 26; k = ⌊100 ÷ 26⌋ = 3; intervalo = round(1 ÷ 0,2) = 5.
      expect(numbers(plan("standard", 8100))).to eq(n: 427, h: 17, b: 26, k: 3, interval: 5)
    end

    it "12.000 → n 434" do
      # n = ⌈450 ÷ (1 + 450 ÷ 12000)⌉ = ⌈433,7⌉ = 434.
      expect(plan("standard", 12_000).n).to eq(434)
    end
  end

  describe "half (2.000 ≤ N < 8.100; Q17: manual de 2013, quarteirões como no standard)" do
    it "faixa" do
      expect(plan("half", 1999)).to eq(:out_of_range)
      expect(plan("half", 8100)).to eq(:out_of_range)
      # n = ⌈450 ÷ (1 + 450 ÷ 2000)⌉ = ⌈367,3⌉ = 368.
      expect(plan("half", 2000).n).to eq(368)
      expect(plan("half", 8099)).to be_a(described_class::Plan)
    end

    it "4.000 com 50 quarteirões → n 405, h 40, b 11, k 4, intervalo 2" do
      # n = ⌈450 ÷ (1 + 450 ÷ 4000)⌉ = ⌈404,5⌉ = 405; h = ⌈0,5 · 4000 ÷ 50⌉ = 40;
      # b = ⌈405 ÷ 40⌉ = ⌈10,1⌉ = 11; k = max(1, ⌊50 ÷ 11⌋) = 4; intervalo = round(1 ÷ 0,5) = 2.
      expect(numbers(plan("half", 4000, 50))).to eq(n: 405, h: 40, b: 11, k: 4, interval: 2)
    end
  end

  describe "census (N < 2.000)" do
    it "1.999 → todos; 2.000 → out_of_range" do
      expect(numbers(plan("census", 1999, 40))).to eq(n: 1999, h: 50, b: 40, k: 1, interval: 1)
      expect(plan("census", 2000)).to eq(:out_of_range)
    end
  end

  it "sem quarteirão ou modo desconhecido → out_of_range" do
    expect(plan("standard", 9000, 0)).to eq(:out_of_range)
    expect(plan("quarter", 9000)).to eq(:out_of_range)
  end

  it "a fração editada muda o intervalo (round(1 ÷ f)); versão antiga sem a chave do half cai no padrão" do
    expect(plan("standard", 8100, liraa_household_fraction: 0.25)).to have_attributes(interval: 4, h: 21) # h = ⌈0,25 · 81⌉ = 21
    expect(plan("standard", 8100, liraa_household_fraction: 0.3).interval).to eq(3) # round(3,33) = 3
    expect(plan("half", 4000, 50, liraa_half_household_fraction: 0.4).interval).to eq(3) # round(2,5) = 3
    old = parameters.except("liraa_half_household_fraction")
    expect(described_class.plan(mode: "half", households_count: 4000, blocks_count: 50, parameters: old).interval).to eq(2)
  end

  it "quarteirões: r, r+k, … até b; r = 3 e k = 3 → 3, 6, …, 78 (26)" do
    positions = described_class.block_positions(plan: plan("standard", 8100), blocks_count: 100, random_start: 3)
    expect(positions).to eq((0...26).map { |step| 3 + (3 * step) })
    expect(positions.last).to eq(78)
    census = plan("census", 10, 4)
    expect(described_class.block_positions(plan: census, blocks_count: 4, random_start: 1)).to eq([ 1, 2, 3, 4 ])
  end

  it "imóveis do quarteirão: sempre a partir do 1º (Q16(b)), ⌈f · M⌉ no intervalo do modo, voltando ao começo" do
    standard = plan("standard", 8100)
    half = plan("half", 4000, 50)
    expect(described_class.household_positions(plan: standard, households_count: 12)).to eq([ 1, 6, 11 ]) # ⌈2,4⌉ = 3
    expect(described_class.household_positions(plan: half, households_count: 12)).to eq([ 1, 3, 5, 7, 9, 11 ]) # ⌈6⌉
    expect(described_class.household_positions(plan: half, households_count: 5)).to eq([ 1, 3, 5 ]) # ⌈2,5⌉ = 3
    expect(described_class.household_positions(plan: plan("census", 10, 4), households_count: 4)).to eq([ 1, 2, 3, 4 ])
    expect(described_class.household_positions(plan: standard, households_count: 0)).to eq([])
    # f = 0,38: intervalo round(2,63) = 3, ⌈0,38 · 8⌉ = 4 → 1, 4, 7 e 10 → volta ao 2.
    wrap = plan("standard", 8100, liraa_household_fraction: 0.38)
    expect(described_class.household_positions(plan: wrap, households_count: 8)).to eq([ 1, 4, 7, 2 ])
  end
end
