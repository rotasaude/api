require "rails_helper"

RSpec.describe "Triagens, Relatórios e Conversas filtrados por bairro (ADR 0023)" do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])
  def filter(raw) = Admin::NeighborhoodFilter.parse(raw)

  let(:suppressed) { Admin::SmallCount::SUPPRESSED }
  let!(:small) { Neighborhood.create!(name: "Batel", source: "seed") }
  let!(:big) { Neighborhood.create!(name: "Centro", source: "seed") }

  # Mesma ideia de spec/queries/admin/overview_classification_filter_spec.rb:
  # nenhum Integer 1..4 solto no JSON filtrado — contagem pequena tem que
  # virar `suppressed`, nunca sobreviver crua em outra chave. skip_keys nomeia
  # chaves que não são contagens de bairro (nenhuma das três queries deste
  # arquivo tem uma, ao contrário de urgentMaxPriority/priority na
  # Classificação — por isso o default é vazio).
  def refute_small_ints_anywhere(node, skip_keys: [])
    walk = lambda do |n|
      case n
      when Hash
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
    3.times { territory_report!(territory_triage!(small)) }
    6.times { territory_report!(territory_triage!(big)) }
    2.times { territory_report!(territory_triage!(nil)) }
    Conversation.create!(phone: "+5541911110000", state: "consented") # WhatsApp, sem cidadão
  end

  describe Admin::TriagesQuery do
    def out(raw) = described_class.call(period: period, filter: filter(raw))

    it "bairro com 1 a 4: tudo suprimido" do
      o = out(small.id)
      expect(o.slice(:started, :completed, :completionRate).values).to all(eq(suppressed))
      expect(o[:series]).to include(suppressed)
      expect(o[:series]).to all(satisfy { |v| v == 0 || v == suppressed })
      expect(o[:byProtocol].sole.slice(:count, :share).values).to all(eq(suppressed))
      refute_small_ints_anywhere(o)
    end

    it "bairro com 5 ou mais: números aparecem" do
      o = out(big.id)
      expect(o).to include(started: 6, completed: 6, completionRate: 100.0)
      expect(o[:byProtocol].sole).to include(count: 6, share: 100)
    end

    it "iniciadas 5 ou mais mas concluídas 1 a 4: completionRate sai suprimida (não dá pra descobrir por subtração)" do
      cabral = Neighborhood.create!(name: "Cabral", source: "seed")
      2.times { territory_triage!(cabral) }
      4.times { territory_triage!(cabral, status: "in_progress") }
      o = out(cabral.id)
      expect(o[:started]).to eq(6)
      expect(o[:completed]).to eq(suppressed)
      expect(o[:completionRate]).to eq(suppressed)
    end

    it "sem filtro: igual ao de antes" do
      expect(out(nil)).to eq(described_class.call(period: period))
      expect(out(nil)[:started]).to eq(11)
    end
  end

  describe Admin::ReportsQuery do
    def out(raw) = described_class.call(period: period, filter: filter(raw))

    # Ruling do controller (2026-09-28): a lista de relatórios sai null
    # sempre que QUALQUER contagem do painel sair suprimida — não só quando
    # o total é 1 a 4 — porque uma linha listada revelaria uma categoria
    # suprimida no mesmo payload. No painel de Relatórios a única contagem é
    # `total`, então na prática a regra continua "null quando total é 1 a 4",
    # mas a spec prova o caso "nada suprimido → lista aparece" à parte,
    # espelhando a Classificação.
    it "bairro com 1 a 4: total suprimido e lista null" do
      o = out(small.id)
      expect(o).to eq(reports: nil, total: suppressed)
      refute_small_ints_anywhere(o)
    end

    it "none: total suprimido e lista null" do
      o = out("none")
      expect(o).to eq(reports: nil, total: suppressed)
      refute_small_ints_anywhere(o)
    end

    it "bairro com 5 ou mais e nada suprimido: lista e total aparecem" do
      o = out(big.id)
      expect(o[:total]).to eq(6)
      expect(o[:reports].size).to eq(6)
    end

    it "bairro com 5 ou mais mas um tier com 1 a 4 linhas: lista sai null mesmo com o total visível" do
      territory_report!(territory_triage!(big, tier: "baixa", priority: 9))
      o = out(big.id)
      expect(o[:total]).to eq(7)
      expect(o[:reports]).to be_nil
    end

    it "sem filtro: igual ao de antes" do
      expect(out(nil)).to eq(described_class.call(period: period))
      expect(out(nil)[:total]).to eq(11)
    end
  end

  describe Admin::ConversationsQuery do
    def out(raw) = described_class.call(period: period, filter: filter(raw))

    it "bairro com 1 a 4: saídas, taxa e tempo médio suprimidos; zeros continuam zero" do
      o = out(small.id)
      exits = o[:exits].to_h { |e| [ e[:key], e[:count] ] }
      expect(exits["completed"]).to eq(suppressed)
      expect(exits["abandoned"]).to eq(0)
      expect([ o[:abandonRate], o[:avgToCompleteMin] ]).to eq([ suppressed, suppressed ])
      expect(o[:live]).to eq(0)
      refute_small_ints_anywhere(o)
    end

    it "bairro com 5 ou mais: números aparecem" do
      o = out(big.id)
      expect(o[:exits].find { |e| e[:key] == "completed" }[:count]).to eq(6)
      expect(o[:avgToCompleteMin]).to eq(5.0)
      expect(o[:abandonRate]).to eq(0.0)
    end

    it "iniciadas 5 ou mais mas abandonadas 1 a 4: abandonRate sai suprimida (não dá pra descobrir por subtração)" do
      cabral = Neighborhood.create!(name: "Cabral", source: "seed")
      4.times { territory_triage!(cabral) }
      2.times { territory_triage!(cabral, status: "in_progress").conversation.update!(state: "abandoned") }
      o = out(cabral.id)
      expect(o[:exits].to_h { |e| [ e[:key], e[:count] ] }["abandoned"]).to eq(suppressed)
      expect(o[:abandonRate]).to eq(suppressed)
    end

    it "none: a conversa do WhatsApp sem cidadão entra, suprimida" do
      o = out("none")
      expect(o[:live]).to eq(suppressed)
      expect(o[:liveActive][:inProgress]).to eq(suppressed)
      refute_small_ints_anywhere(o)
    end

    it "sem filtro: igual ao de antes" do
      expect(out(nil)).to eq(described_class.call(period: period))
    end
  end
end
