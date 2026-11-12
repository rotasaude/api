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
    it "7 reclamações e 2 elogios: o elogio escondido leva também a reclamação (supressão complementar); os totais saem" do
      received!(7, kind: "complaint")
      received!(2, kind: "praise")

      result = panel
      expect(result[:period]).to eq(from: "2026-01-01", to: "2026-12-31")
      # 9 (o total) é derivável de qualquer partição: a reclamação cairia por subtração
      expect(result[:by_kind]).to eq(complaint: suppressed, praise: suppressed, report: suppressed, suggestion: suppressed,
                                     request: suppressed, total: 9)
      expect(result[:by_channel]).to include(web: 9, total: 9)
      expect(result[:by_state]).to include(received: 9, total: 9)
      expect(result[:total]).to eq(9)
    end

    it "com célula escondida, os zeros se escondem também; esconde as menores visíveis até haver 2 escondidas somando 5 ou mais" do
      received!(2, kind: "complaint")
      received!(3, kind: "praise")
      received!(20, kind: "request")
      expect(panel[:by_kind]).to eq(complaint: suppressed, praise: suppressed, report: suppressed, suggestion: suppressed, request: 20, total: 25)

    end

    it "escondendo a menor visível, a soma escondida ainda pode ficar abaixo de 5: esconde a seguinte" do
      received!(1, kind: "complaint")
      received!(2, kind: "praise")
      received!(9, kind: "report")
      received!(20, kind: "request")
      expect(panel[:by_kind]).to eq(complaint: suppressed, praise: suppressed, report: suppressed, suggestion: suppressed, request: 20, total: 32)
    end

    it "empate na menor visível: esconde todas as empatadas juntas, nunca pela ordem das células" do
      received!(5, kind: "complaint")
      received!(4, kind: "report")
      received!(4, kind: "praise")
      received!(30, kind: "request")
      expect(panel[:by_kind]).to eq(complaint: 5, report: suppressed, praise: suppressed, suggestion: suppressed, request: 30, total: 43)
    end

    it "partição só de células de 1 a 4: todas escondidas, nenhuma é fixada pelo total" do
      received!(3)
      expect(panel[:by_channel]).to eq(web: suppressed, in_person: suppressed, phone: suppressed, ouvidorsus: suppressed, total: 3)
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

    it "por unidade referida: só as que têm manifestação, por nome; a de 1 a 4 leva a menor visível junto" do
      big = HealthUnit.create!(name: "UBS Zeta", kind: "ubs")
      small = HealthUnit.create!(name: "UBS Alfa", kind: "ubs")
      mid = HealthUnit.create!(name: "UBS Meio", kind: "ubs")
      received!(6, referred_health_unit: big)
      received!(2, referred_health_unit: small)
      received!(7, referred_health_unit: mid)
      received!(3)

      expect(panel[:by_health_unit]).to eq([ { id: small.id, name: "UBS Alfa", count: suppressed },
                                             { id: mid.id, name: "UBS Meio", count: 7 },
                                             { id: big.id, name: "UBS Zeta", count: suppressed } ])
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
      # o 2 do `unclassified` leva o menor visível (7) junto
      expect(items.first(2)).to eq([ { id: parent.id, name: parent.name, count: 11 }, { id: other.id, name: other.name, count: suppressed } ])
      expect(items.size).to eq(OmbudsmanSubject.where(parent_id: nil).count + 1)
      expect(items[0..-2].map { |item| item[:id] }).to eq(OmbudsmanSubject.where(parent_id: nil).order(:position, :name).pluck(:id))
    end

    it "sem manifestação sem assunto, o `unclassified` sai com 0" do
      expect(panel[:by_subject].last).to eq(id: nil, name: nil, unclassified: true, count: 0)
    end
  end

  describe "no prazo (Q17)" do
    it "9 de 15 concluídas até o vencimento: 60.0, pelo prazo vigente" do
      9.times { concluded!(days: 30) }
      6.times { concluded!(days: 31) }
      received!(6) # abertas não entram

      expect(panel[:on_time_rate]).to eq(60.0)

      OmbudsmanSetting.current.update!(response_days: 31)
      expect(panel[:on_time_rate]).to eq(100.0)
    end

    it "conta a prorrogação e os dias suspensos do ciclo" do
      5.times { concluded!(days: 40, extended: true) }
      5.times { concluded!(days: 33, suspended_days: 3) }
      5.times { concluded!(days: 34, suspended_days: 3) }

      expect(panel[:on_time_rate]).to eq(66.7)
    end

    it "o complemento (as fora do prazo) de 1 a 4 também esconde a taxa" do
      9.times { concluded!(days: 30) }
      2.times { concluded!(days: 31) }
      expect(panel[:on_time_rate]).to eq(suppressed)
    end

    it "arquivada a partir de awaiting_complement conta pelo prazo com os dias suspensos fechados" do
      5.times { manifestation!(received_at: Time.utc(2026, 6, 10, 15), state: "archived", archive_reason: "no_complement", suspended_days: 3, concluded_at: Time.utc(2026, 6, 10, 15) + 33.days) }
      5.times { manifestation!(received_at: Time.utc(2026, 6, 10, 15), state: "archived", archive_reason: "no_complement", suspended_days: 3, concluded_at: Time.utc(2026, 6, 10, 15) + 34.days) }
      expect(panel[:on_time_rate]).to eq(50.0)
    end

    it "reaberta e concluída de novo: vale o prazo do ciclo vigente, não o do recebimento" do
      5.times { concluded!(days: 35, cycle: 2, cycle_started_on: Date.new(2026, 6, 20)) } # 25 dias no ciclo 2
      5.times { concluded!(days: 52, cycle: 2, cycle_started_on: Date.new(2026, 6, 20)) } # 42 dias no ciclo 2
      expect(panel[:on_time_rate]).to eq(50.0)
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
      5.times { concluded!(resolution: "not_resolved") }
      3.times { concluded!(kind: "praise") }

      expect(panel[:resolution_rate]).to eq(54.5)
    end

    it "o complemento de 1 a 4 esconde a taxa" do
      6.times { concluded!(resolution: "resolved") }
      4.times { concluded!(resolution: "not_resolved") }
      expect(panel[:resolution_rate]).to eq(suppressed)
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

    it "com 3 respostas a média e a contagem escondem; o total sai" do
      3.times { satisfaction!(concluded!) }

      result = panel[:satisfaction]
      expect(result[:avg_score]).to eq(suppressed)
      expect(result[:responses]).to eq(3)
      expect(result[:met]).to eq(yes: suppressed, partly: suppressed, no: suppressed)
      expect(result[:clear]).to eq(yes: suppressed, no: suppressed)
    end

    it "clear: a parte de 1 a 4 leva a outra junto (o total das respostas sai e as entrega por subtração)" do
      6.times { satisfaction!(concluded!, clear: true) }
      2.times { satisfaction!(concluded!, clear: false) }

      result = panel[:satisfaction]
      expect(result[:responses]).to eq(8)
      expect(result[:clear]).to eq(yes: suppressed, no: suppressed)
      expect(result[:met]).to eq(yes: 8, partly: 0, no: 0)
    end

    it "met: a parte de 1 a 4 leva a menor visível junto; o resto e a média saem" do
      6.times { satisfaction!(concluded!, met: "yes", clear: true, score: 5) }
      5.times { satisfaction!(concluded!, met: "partly", clear: true, score: 3) }
      satisfaction!(concluded!, met: "no", clear: true, score: 1)

      result = panel[:satisfaction]
      expect(result[:met]).to eq(yes: 6, partly: suppressed, no: suppressed)
      expect(result[:clear]).to eq(yes: 12, no: 0)
      expect(result[:responses]).to eq(12)
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

  describe "taxa e média que repetem uma célula de by_state" do
    it "on_time_rate e avg_days_to_conclude escondem quando `answered` ou `archived` está escondido" do
      5.times { concluded!(days: 3) }
      expect(panel).to include(on_time_rate: 100.0, avg_days_to_conclude: 3.0)

      received!(2) # `received` 2 esconde a menor visível (answered 5 junto com os zeros)
      result = panel
      expect(result[:by_state]).to include(answered: suppressed, archived: suppressed)
      expect(result[:on_time_rate]).to eq(suppressed)
      expect(result[:avg_days_to_conclude]).to eq(suppressed)
    end

    it "archived escondido também esconde" do
      5.times { concluded!(days: 3) }
      2.times { manifestation!(received_at: Time.utc(2026, 6, 10, 15), state: "archived", archive_reason: "improper", concluded_at: Time.utc(2026, 6, 12, 15)) }
      expect(panel[:by_state]).to include(archived: suppressed, answered: suppressed)
      expect(panel[:on_time_rate]).to eq(suppressed)
      expect(panel[:avg_days_to_conclude]).to eq(suppressed)
    end
  end

  # Q53: nenhuma célula escondida tem um único valor consistente com o que
  # fica à mostra (as outras células e o total), por partição, em toda a grade.
  describe "supressão complementar (propriedade)" do
    def protect(values) = described_class.send(:protect, values.each_with_index.to_h { |value, index| [ index, value ] }).values

    def pinned(range, cells)
      outputs = Hash.new { |hash, key| hash[key] = [] }
      range.to_a.repeated_permutation(cells) { |values| outputs[[ values.sum, protect(values) ]] << values }
      outputs.filter_map do |(total, out), preimages|
        next if total < 1

        index = out.each_index.find { |i| out[i] == suppressed && preimages.map { |values| values[i] }.uniq.size < 2 }
        [ total, out ] if index
      end
    end

    it "partição de 4 células (0..8), de 3 (0..10) e de 2 (0..12, o caso de `clear`)" do
      expect(pinned(0..8, 4)).to be_empty
      expect(pinned(0..10, 3)).to be_empty
      expect(pinned(0..12, 2)).to be_empty
    end

    it "a saída não depende da ordem das células" do
      [ [ 5, 4, 4, 0 ], [ 3, 7, 7, 1 ], [ 6, 5, 5, 2 ] ].each do |values|
        shown = protect(values).map { |cell| cell == suppressed }
        expect(protect(values.reverse).map { |cell| cell == suppressed }).to eq(shown.reverse)
      end
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
