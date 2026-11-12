require "rails_helper"

# Módulo 33, Task 16 (ADR 0051; contrato §11; §16 Q17, Q28, Q49): o painel da
# ouvidoria. Universo = manifestações recebidas no período (dia local);
# contagens de 1 a 4 escondidas (`{ suppressed: true }`); médias com 1..4 casos
# escondidas e sem caso `nil`; nenhum texto no resultado.
RSpec.describe Ombudsman::Panel do
  include ActiveSupport::Testing::TimeHelpers

  let(:suppressed) { Analytics::Suppression::SUPPRESSED }
  let!(:city) { ombudsman_city! }
  let(:now) { Time.utc(2026, 11, 11, 15) }
  let(:today) { Date.new(2026, 11, 11) }
  let(:from) { Date.new(2026, 1, 1) }
  let(:to) { Date.new(2026, 12, 31) }

  before { travel_to(now) }
  after { travel_back }

  def panel(from: self.from, to: self.to) = described_class.call(from: from, to: to, today: today)

  def received!(count = 1, at: Time.utc(2026, 6, 10, 15), **attrs) = Array.new(count) { manifestation!(received_at: at, **attrs) }

  # Concluída (answered) no dia `days` depois do recebimento.
  def concluded!(days: 3, received: Time.utc(2026, 6, 10, 15), kind: "complaint", resolution: nil, **attrs)
    manifestation!(received_at: received, kind: kind, state: "answered", concluded_at: received + days.days, resolution: resolution, **attrs)
  end

  def satisfaction!(manifestation, met: "yes", clear: true, score: 5)
    OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: manifestation, met: met, clear: clear, score: score)
  end

  describe "contagens e supressão" do
    it "7 reclamações e 2 elogios: reclamação à mostra, elogio e o total do grupo escondidos" do
      received!(7, kind: "complaint")
      received!(2, kind: "praise")

      result = panel
      expect(result[:period]).to eq(from: "2026-01-01", to: "2026-12-31")
      expect(result[:by_kind]).to include(complaint: 7, praise: suppressed, report: 0, suggestion: 0, request: 0)
      expect(result[:by_kind][:total]).to eq(suppressed)
      # o total de cada grupo (e o de cima) sai igual: nenhum deixa o elogio por subtração
      expect(result[:by_channel][:total]).to eq(suppressed)
      expect(result[:by_state][:total]).to eq(suppressed)
      expect(result[:total]).to eq(suppressed)
    end

    it "sem parte escondida, os totais saem" do
      received!(5, kind: "complaint")
      received!(6, kind: "praise", channel: "phone")

      result = panel
      expect(result[:total]).to eq(11)
      expect(result[:by_kind]).to include(complaint: 5, praise: 6, total: 11)
      expect(result[:by_channel]).to include(web: 5, phone: 6, in_person: 0, ouvidorsus: 0, total: 11)
      expect(result[:by_state]).to include(received: 11, answered: 0, total: 11)
    end

    it "só conta o que foi recebido no período, pelo dia local" do
      received!(5, at: Time.utc(2026, 3, 1, 2, 59)) # 28/02 23:59 em Brasília: fora
      received!(5, at: Time.utc(2026, 3, 1, 3, 0))  # 01/03 00:00: dentro
      received!(5, at: Time.utc(2026, 4, 1, 2, 59)) # 31/03 23:59: dentro
      received!(5, at: Time.utc(2026, 4, 1, 3, 0))  # 01/04 00:00: fora

      result = panel(from: Date.new(2026, 3, 1), to: Date.new(2026, 3, 31))
      expect(result[:total]).to eq(10)
      expect(result[:period]).to eq(from: "2026-03-01", to: "2026-03-31")
    end

    it "por unidade referida: só as que têm manifestação, por nome, com a contagem escondida de 1 a 4" do
      big = HealthUnit.create!(name: "UBS Zeta", kind: "ubs")
      small = HealthUnit.create!(name: "UBS Alfa", kind: "ubs")
      received!(6, referred_health_unit: big)
      received!(2, referred_health_unit: small)
      received!(3)

      expect(panel[:by_health_unit]).to eq([ { id: small.id, name: "UBS Alfa", count: suppressed },
                                             { id: big.id, name: "UBS Zeta", count: 6 } ])
    end
  end

  describe "por assunto (Q49)" do
    it "agrupa no primeiro nível e põe `unclassified` por último" do
      parent = OmbudsmanSubject.where(parent_id: nil).order(:position).first
      leaf = parent.children.first
      other = OmbudsmanSubject.where(parent_id: nil).order(:position).second
      received!(6, subject: leaf)
      received!(5, subject: parent)
      received!(7, subject: other)
      received!(2)

      items = panel[:by_subject]
      expect(items.last).to eq(id: nil, name: nil, unclassified: true, count: suppressed)
      expect(items.first(2)).to eq([ { id: parent.id, name: parent.name, count: 11 }, { id: other.id, name: other.name, count: 7 } ])
      expect(items.size).to eq(OmbudsmanSubject.where(parent_id: nil).count + 1)
      expect(items[0..-2].map { |item| item[:id] }).to eq(OmbudsmanSubject.where(parent_id: nil).order(:position, :name).pluck(:id))
    end

    it "sem manifestação sem assunto, o `unclassified` sai com 0" do
      expect(panel[:by_subject].last).to eq(id: nil, name: nil, unclassified: true, count: 0)
    end
  end

  describe "no prazo (Q17)" do
    it "6 de 8 concluídas até o vencimento: 75.0, pelo prazo vigente" do
      6.times { concluded!(days: 30) }
      2.times { concluded!(days: 31) }
      received!(3) # abertas não entram

      expect(panel[:on_time_rate]).to eq(75.0)

      OmbudsmanSetting.current.update!(response_days: 31)
      expect(panel[:on_time_rate]).to eq(100.0)
    end

    it "conta a prorrogação e os dias suspensos do ciclo" do
      5.times { concluded!(days: 40, extended: true) }
      5.times { concluded!(days: 33, suspended_days: 3) }
      5.times { concluded!(days: 34, suspended_days: 3) }

      expect(panel[:on_time_rate]).to eq(66.7)
    end

    it "sem concluída → nil; de 1 a 4 concluídas → escondida" do
      expect(panel[:on_time_rate]).to be_nil
      3.times { concluded! }
      expect(panel[:on_time_rate]).to eq(suppressed)
    end
  end

  describe "dias para concluir" do
    it "média em dias locais do ciclo, com 5 ou mais casos" do
      [ 1, 2, 3, 4, 7 ].each { |days| concluded!(days: days) }
      expect(panel[:avg_days_to_conclude]).to eq(3.4)
    end

    it "3 casos → escondida; nenhum → nil" do
      expect(panel[:avg_days_to_conclude]).to be_nil
      3.times { concluded! }
      expect(panel[:avg_days_to_conclude]).to eq(suppressed)
    end
  end

  describe "resolutividade" do
    it "sobre as que têm resolutividade; as de tipo sem resolutividade ficam de fora" do
      6.times { concluded!(resolution: "resolved") }
      4.times { concluded!(resolution: "not_resolved") }
      3.times { concluded!(kind: "praise") }

      expect(panel[:resolution_rate]).to eq(60.0)
    end

    it "sem nenhuma → nil; poucas → escondida" do
      expect(panel[:resolution_rate]).to be_nil
      3.times { concluded!(resolution: "resolved") }
      expect(panel[:resolution_rate]).to eq(suppressed)
    end
  end

  describe "satisfação" do
    it "sem resposta: zeros e média nula" do
      concluded!
      expect(panel[:satisfaction]).to eq(responses: 0, met: { yes: 0, partly: 0, no: 0 }, clear: { yes: 0, no: 0 }, avg_score: nil)
    end

    it "com 3 respostas a média e o total ficam escondidos" do
      3.times { satisfaction!(concluded!) }

      result = panel[:satisfaction]
      expect(result[:avg_score]).to eq(suppressed)
      expect(result[:responses]).to eq(suppressed)
      expect(result[:met][:yes]).to eq(suppressed)
    end

    it "com respostas suficientes, as contagens e a média saem; a parte de 1 a 4 e o total do grupo ficam escondidos" do
      6.times { satisfaction!(concluded!, met: "yes", clear: true, score: 5) }
      5.times { satisfaction!(concluded!, met: "partly", clear: true, score: 3) }
      satisfaction!(concluded!, met: "no", clear: true, score: 1)

      result = panel[:satisfaction]
      expect(result[:met]).to eq(yes: 6, partly: 5, no: suppressed)
      expect(result[:clear]).to eq(yes: 12, no: 0)
      expect(result[:responses]).to eq(suppressed)
      expect(result[:avg_score]).to eq(3.8)
    end

    it "só conta respostas de manifestações recebidas no período" do
      5.times { satisfaction!(concluded!(received: Time.utc(2025, 6, 10, 15)), met: "no", clear: false, score: 1) }
      6.times { satisfaction!(concluded!, met: "yes", clear: true, score: 5) }

      result = panel[:satisfaction]
      expect(result).to include(responses: 6, avg_score: 5.0)
      expect(result[:met]).to eq(yes: 6, partly: 0, no: 0)
      expect(result[:clear]).to eq(yes: 6, no: 0)
    end
  end

  it "não leva nenhum texto: nem o corpo, nem o protocolo" do
    received!(6)
    3.times { satisfaction!(concluded!) }

    json = panel.to_json
    expect(json).not_to include(OmbudsmanHelpers::BODY)
    expect(json).not_to match(/\d{4}-\d{6}/)
  end
end
