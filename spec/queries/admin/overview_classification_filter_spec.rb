require "rails_helper"

RSpec.describe "Visão geral e Classificação filtradas por bairro (ADR 0023)" do
  include ActiveSupport::Testing::TimeHelpers

  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])
  def filter(raw) = Admin::NeighborhoodFilter.parse(raw)

  let(:suppressed) { Admin::SmallCount::SUPPRESSED }
  let!(:small) { Neighborhood.create!(name: "Batel", source: "seed") }
  let!(:big) { Neighborhood.create!(name: "Centro", source: "seed") }

  # Nenhum Integer 1..4 solto no JSON filtrado: contagem pequena tem que
  # virar `suppressed`, nunca sobreviver crua em outra chave (ex.: dentro de
  # uma linha de amostra). Exceções: urgentMaxPriority (config, não contagem),
  # priority das linhas de amostra (já é o próprio caso, não uma contagem de
  # bairro) e o KPI "failed" (jobs, ignora o filtro por completo).
  def refute_small_ints_anywhere(node, skip_keys: %i[urgentMaxPriority priority])
    walk = lambda do |n|
      case n
      when Hash
        next if n[:id] == "failed"
        n.each { |k, v| walk.call(v) unless skip_keys.include?(k) }
      when Array
        n.each { |v| walk.call(v) }
      when Integer
        expect(n).not_to be_between(1, 4), "found an un-suppressed small int (#{n})"
      end
    end
    walk.call(node)
  end

  before do
    3.times { territory_triage!(small) }
    6.times { territory_triage!(big) }
    2.times { territory_triage!(nil) }
    Conversation.create!(phone: "+5541911110000", state: "consented") # WhatsApp, sem cidadão
  end

  describe Admin::OverviewQuery do
    def kpis(raw) = described_class.call(period: period, filter: filter(raw))[:kpis].index_by { |k| k[:id] }

    it "sem filtro: a cidade inteira, sem supressão" do
      expect(kpis(nil).transform_values { |k| k[:value] }).to include("done" => 11, "urgent" => 11, "completion" => 100.0)
      expect(described_class.call(period: period)[:kpis]).to eq(described_class.call(period: period, filter: filter(nil))[:kpis])
    end

    it "bairro com 1 a 4: KPI, pontos da série e taxa suprimidos; jobs com falha não" do
      k = kpis(small.id)
      expect(k["done"][:value]).to eq(suppressed)
      expect(k["urgent"][:value]).to eq(suppressed)
      expect(k["done"][:spark]).to all(satisfy { |v| v == 0 || v == suppressed })
      expect(k["done"][:spark]).to include(suppressed)
      expect(k["completion"]).to include(value: suppressed, tone: "neutral")
      expect(k["failed"][:value]).to eq(SolidQueue::FailedExecution.count)
      refute_small_ints_anywhere(k)
    end

    it "bairro com 5 ou mais: o número aparece" do
      k = kpis(big.id)
      expect(k["done"][:value]).to eq(6)
      expect(k["completion"][:value]).to eq(100.0)
    end

    it "iniciadas 5 ou mais mas concluídas 1 a 4: completion sai suprimida (não dá pra descobrir por subtração)" do
      cabral = Neighborhood.create!(name: "Cabral", source: "seed")
      2.times { territory_triage!(cabral) }
      4.times { territory_triage!(cabral, status: "in_progress") }
      k = kpis(cabral.id)
      expect(k["done"][:value]).to eq(suppressed)
      expect(k["completion"]).to include(value: suppressed, tone: "neutral")
    end

    it "none: triagens sem bairro; conversas ativas sem cidadão ou sem bairro" do
      k = kpis("none")
      expect(k["done"][:value]).to eq(suppressed)
      expect(k["active"][:value]).to eq(suppressed)
    end
  end

  describe Admin::ClassificationQuery do
    def out(raw) = described_class.call(period: period, filter: filter(raw))

    it "bairro com 1 a 4: contagens, apelidos, share e série suprimidos; amostra null" do
      o = out(small.id)
      expect(o[:tiers].map { |t| t[:count] }).to all(eq(suppressed))
      expect([ o[:urgent], o[:priorityTrue] ]).to eq([ suppressed, suppressed ])
      expect(o[:urgentTrend]).to include(suppressed)
      expect(o[:byMode].map { |m| [ m[:count], m[:share] ] }).to all(eq([ suppressed, suppressed ]))
      expect(o[:byProtocol].flat_map { |r| r[:counts].values }).to all(eq(suppressed))
      expect(o[:sampleTriages]).to be_nil
      refute_small_ints_anywhere(o)
    end

    it "bairro grande com uma categoria de 1 caso: a categoria e o share dela saem suppressed; amostra vem null (revelaria o caso suprimido)" do
      territory_triage!(big, tier: "baixa", priority: 9)
      o = out(big.id)
      counts = o[:tiers].to_h { |t| [ t[:key], t[:count] ] }
      expect(counts).to eq("alta" => 6, "baixa" => suppressed)
      expect(o[:byProtocol].sole[:counts]).to eq("alta" => 6, "baixa" => suppressed)
      expect(o[:byMode].sole).to include(count: 7, share: 100)
      expect(o[:sampleTriages]).to be_nil
    end

    it "bairro grande sem nenhuma contagem suprimida: a amostra aparece" do
      o = out(big.id)
      expect(o[:tiers]).to all(satisfy { |t| t[:count] != suppressed })
      expect(o[:sampleTriages].size).to eq(6)
    end

    it "período por hora: uma hora com 1 a 4 urgentes esconde a amostra mesmo com as demais contagens grandes" do
      travel_to(Time.utc(2026, 9, 28, 15, 0, 0)) do # 12h em America/Sao_Paulo
        hourly = Admin::Api::Period.parse(key: "today", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])
        portao = Neighborhood.create!(name: "Portão", source: "seed")
        5.times { territory_triage!(portao, tier: "alta", priority: 1, created_at: 5.hours.ago) }
        2.times { territory_triage!(portao, tier: "alta", priority: 1, created_at: 1.hour.ago) }

        o = described_class.call(period: hourly, filter: filter(portao.id))

        expect(o[:tiers].sole[:count]).to eq(7)
        expect(o[:urgent]).to eq(7)
        expect(o[:byMode].sole[:count]).to eq(7)
        expect(o[:byProtocol].sole[:counts].values).to all(eq(7))
        expect(o[:urgentTrend]).to include(suppressed)
        expect(o[:sampleTriages]).to be_nil
      end
    end

    it "sem filtro: igual ao de antes" do
      expect(out(nil)).to eq(described_class.call(period: period))
      expect(out(nil)[:urgent]).to eq(11)
    end
  end
end
