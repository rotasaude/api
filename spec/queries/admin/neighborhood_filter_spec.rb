require "rails_helper"
require "bigdecimal"

RSpec.describe Admin::NeighborhoodFilter do
  let(:suppressed) { Admin::SmallCount::SUPPRESSED }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:antigo) { Neighborhood.create!(name: "Ahu", source: "seed", active: false) }

  describe ".parse" do
    it "ausente ou vazio: desligado, descritor nil" do
      [ nil, "" ].each do |raw|
        filter = described_class.parse(raw)
        expect(filter.active?).to be(false)
        expect(filter.descriptor).to be_nil
      end
    end

    it "none e bairro (ativo ou inativo) ligam o filtro" do
      expect(described_class.parse("none").descriptor).to eq("none")
      expect(described_class.parse(centro.id).descriptor).to eq(id: centro.id, name: "Centro")
      expect(described_class.parse(antigo.id).active?).to be(true)
    end

    it "texto que não é UUID, UUID inexistente, lista ou objeto: Invalid" do
      [ "abc", SecureRandom.uuid, [ centro.id ], { "id" => centro.id } ].each do |raw|
        expect { described_class.parse(raw) }.to raise_error(described_class::Invalid), raw.inspect
      end
    end
  end

  describe "recortes" do
    before do
      territory_triage!(centro)
      territory_triage!(nil)
      Conversation.create!(phone: "+5541911110000", state: "consented") # WhatsApp, sem cidadão
    end

    it "triagens pelo bairro copiado; none = sem bairro" do
      expect(described_class.parse(centro.id).triages(Triage.all).count).to eq(1)
      expect(described_class.parse("none").triages(Triage.all).count).to eq(1)
      expect(described_class.off.triages(Triage.all).count).to eq(2)
    end

    it "conversas pelo bairro atual do cidadão; none inclui conversa sem cidadão" do
      expect(described_class.parse(centro.id).conversations(Conversation.all).count).to eq(1)
      expect(described_class.parse("none").conversations(Conversation.all).count).to eq(2)
    end

    it "relatórios pelo bairro da triagem" do
      Triage.find_each { |t| territory_report!(t) }
      expect(described_class.parse(centro.id).report_snapshots(ReportSnapshot.all).count).to eq(1)
    end

    it "relatórios em modo none: só os da triagem sem bairro" do
      Triage.find_each { |t| territory_report!(t) }
      expect(described_class.parse("none").report_snapshots(ReportSnapshot.all).count).to eq(1)
    end
  end

  describe "conversas quando o bairro do cidadão muda depois da triagem" do
    it "seguem o bairro ATUAL do cidadão, mesmo que difira do copiado na triagem" do
      triage = territory_triage!(centro)
      triage.conversation.citizen.update!(neighborhood: antigo)

      expect(described_class.parse(antigo.id).conversations(Conversation.all).count).to eq(1)
      expect(described_class.parse(centro.id).conversations(Conversation.all).count).to eq(0)
    end
  end

  describe "supressão" do
    let(:on) { described_class.parse(centro.id) }
    let(:off) { described_class.off }

    it "SUPPRESSED é congelado" do
      expect(suppressed).to be_frozen
    end

    it "count: 1 a 4 suprimido, 0 e 5+ aparecem; desligado não mexe" do
      expect([ 0, 1, 4, 5 ].map { |n| on.count(n) }).to eq([ 0, suppressed, suppressed, 5 ])
      expect(off.count(3)).to eq(3)
    end

    it "count: fronteira 4/5" do
      expect(on.count(4)).to eq(suppressed)
      expect(on.count(5)).to eq(5)
    end

    it "count: qualquer Numeric inteiro de 1 a 4 é suprimido, não só Integer" do
      expect(on.count(3.0)).to eq(suppressed)
      expect(on.count(BigDecimal("3"))).to eq(suppressed)
    end

    it "count: parâmetro que não é Numeric (nem nil) levanta ArgumentError com o filtro ligado" do
      expect { on.count("3") }.to raise_error(ArgumentError)
      expect(on.count(nil)).to be_nil
    end

    it "series: ponto a ponto" do
      expect(on.series([ 0, 2, 7 ])).to eq([ 0, suppressed, 7 ])
      expect(off.series([ 0, 2, 7 ])).to eq([ 0, 2, 7 ])
    end

    it "series: Hash em vez de Array levanta ArgumentError com o filtro ligado" do
      expect { on.series({ a: 2 }) }.to raise_error(ArgumentError)
    end

    it "over: taxa ou média sobre total de 1 a 4 some" do
      expect(on.over(3, 66.7)).to eq(suppressed)
      expect(on.over(0, 0.0)).to eq(0.0)
      expect(on.over(6, 50.0)).to eq(50.0)
      expect(off.over(3, 66.7)).to eq(66.7)
    end

    it "over: fronteira 4/5 no total" do
      expect(on.over(4, 50.0)).to eq(suppressed)
      expect(on.over(5, 50.0)).to eq(50.0)
    end

    it "share: some se a contagem OU o total for de 1 a 4" do
      expect(on.share(1, 10, 10)).to eq(suppressed)
      expect(on.share(5, 3, 100)).to eq(suppressed)
      expect(on.share(5, 10, 50)).to eq(50)
    end

    it "share: com o filtro desligado, passa a entrada intacta mesmo com contagem/total pequenos" do
      expect(off.share(1, 3, 10)).to eq(10)
    end

    it "list: null quando o total é de 1 a 4" do
      expect(on.list(3, [ :a ])).to be_nil
      expect(on.list(5, [ :a ])).to eq([ :a ])
      expect(off.list(3, [ :a ])).to eq([ :a ])
    end
  end
end
