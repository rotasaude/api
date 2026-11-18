require "rails_helper"

# Módulo 35a (contrato §7; Q16(e)): IIP, IB e ITR do LIRAa por estrato e
# município, das inspeções worked válidas ligadas aos itens; uma casa, meio
# para cima, antes de classificar; provisório com amostra sem resultado;
# congelado no fechamento.
RSpec.describe VectorControl::Liraa::Index, type: :model do
  let(:bands) { [ 1.0, 4.0 ] }

  def indices(inspected, positive_households, positive_containers = positive_households, by_group = {})
    described_class.indices(inspected: inspected, positive_households: positive_households, positive_containers: positive_containers,
                            by_group: by_group, bands: bands)
  end

  describe ".indices (puro)" do
    it "100 inspecionados, 3 imóveis positivos → IIP 3.0 Alerta; 4 → 4.0 Risco; 9 em 1.000 → 0.9 Satisfatório" do
      expect(indices(100, 3)).to include(iip: "3.0", iip_class: "Alerta")
      expect(indices(100, 4)).to include(iip: "4.0", iip_class: "Risco")
      expect(indices(1000, 9)).to include(iip: "0.9", iip_class: "Satisfatório")
      expect(indices(1000, 39)).to include(iip: "3.9", iip_class: "Alerta")
    end

    it "arredonda a uma casa, meio para cima, antes de classificar (Q16(e))" do
      expect(indices(2000, 19)).to include(iip: "1.0", iip_class: "Alerta") # 0,95 → 1,0
      expect(indices(10_000, 395)).to include(iip: "4.0", iip_class: "Risco") # 3,95 → 4,0
      expect(indices(10_000, 94)).to include(iip: "0.9", iip_class: "Satisfatório") # 0,94 → 0,9
      expect(indices(3, 1)).to include(iip: "33.3")
    end

    it "IB conta recipientes positivos; ITR(A2) = positivos A2 ÷ positivos × 100" do
      result = indices(100, 3, 4, "A2" => 3, "B" => 1)
      expect(result[:ib]).to eq("4.0")
      expect(result[:itr]).to eq("A1" => "0.0", "A2" => "75.0", "B" => "25.0", "C" => "0.0", "D1" => "0.0", "D2" => "0.0", "E" => "0.0")
    end

    it "sem inspecionado ou sem positivo: índices nulos, sem classe" do
      expect(indices(0, 0)).to include(iip: nil, ib: nil, iip_class: nil)
      expect(indices(10, 0)[:itr].values).to all(be_nil)
    end
  end

  describe ".for" do
    before { vector_city! }

    let(:area) { registry_micro_area!(code: "05") }
    let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
    let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
    let(:homes) { liraa_households!(block, 5, micro_area: area) }
    let(:day) { home_visit_day! }
    let(:survey) { LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: Time.zone.today, ends_on: Time.zone.today + 6) }
    let!(:stratum) { LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "standard") }
    let!(:empty) { LiraaStratum.create!(liraa_survey: survey, name: "Estrato 2", mode: "census") }
    let!(:item_list) do
      list = homes.first(4).each_with_index.map do |home, i|
        LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: home, position: i + 1)
      end
      list << LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: homes[4], position: 5, substitute_of: list[3])
      survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 0)
      list
    end

    def inspect!(item, situation = "worked", hour: 9)
      visit = home_visit!(day: day, household: item.household, micro_area: area, occurred_at: Time.zone.today.in_time_zone.change(hour: hour))
      VectorInspection.create!(home_visit: visit, household_id: item.household_id, activity: "liraa", work_type: "routine",
                               situation: situation, educational_action: false, liraa_draw_item_id: item.id)
    end

    def sample!(inspection, group, aegypti: nil, number: inspection.samples.count + 1)
      sample = VectorSample.create!(vector_inspection_id: inspection.id, number: number, deposit_group: group, larvae_collected: 5,
                                    label: "#{SecureRandom.hex(4).upcase}-#{format('%02d', number)}")
      result!(sample, aegypti) if aegypti
      sample
    end

    def result!(sample, aegypti)
      sample.update!(examined_larvae: 5, aegypti_larvae: aegypti, albopictus_larvae: 0, result_at: Time.current,
                     result_by_user_id: vector_lab!.id)
    end

    def withdraw!(inspection)
      inspection.home_visit.update!(withdrawn_at: Time.current, withdrawn_by_user: day.user, withdrawal_reason: "registrada no imóvel errado")
    end

    it "por estrato e município: só worked válidas, a mais recente por item; provisório até o resultado" do
      a, b, c, d, = item_list
      first = inspect!(a, hour: 9)
      sample!(first, "A2", aegypti: 2)
      sample!(first, "B", aegypti: 0)
      pending = sample!(inspect!(b, hour: 9), "D1")
      old = inspect!(c, hour: 8) # positiva, mas retirada
      sample!(old, "A1", aegypti: 3)
      withdraw!(old)
      inspect!(c, hour: 10)
      inspect!(d, "closed", hour: 9)
      d.update!(status: "substituted")

      result = described_class.for(survey)
      row = result[:strata].first
      expect(row).to include(id: stratum.id, name: "Estrato 1", inspected: 3, positive_households: 1, positive_containers: 1,
                             iip: "33.3", ib: "33.3", iip_class: "Risco", provisional: true, planned: 4, substitutions: 1, missing: 0)
      expect(row[:itr]).to include("A2" => "100.0", "A1" => "0.0")
      expect(result[:strata].last).to include(id: empty.id, inspected: 0, iip: nil, iip_class: nil, provisional: false, planned: 0)
      expect(result[:municipality]).to include(inspected: 3, positive_households: 1, iip: "33.3", provisional: true, planned: 4)

      result!(pending, 0)
      expect(described_class.for(survey)[:strata].first[:provisional]).to be(false)
    end

    it "Q24: fechado com amostras sem resultado → provisório; o resultado tardio muda os positivos; o último o torna final" do
      a, b, = item_list
      first = sample!(inspect!(a), "A2")
      last = sample!(inspect!(b), "B")
      survey.update!(status: "closed", closed_at: Time.current)
      expect(described_class.for(survey)[:strata].first).to include(inspected: 2, positive_households: 0, provisional: true)

      result!(first, 3)
      expect(described_class.for(survey)[:strata].first).to include(positive_households: 1, iip: "50.0", provisional: true)

      result!(last, 0)
      row = described_class.for(survey)[:strata].first
      expect(row).to include(inspected: 2, positive_households: 1, positive_containers: 1, iip: "50.0", provisional: false)
      expect(described_class.for(survey)[:municipality][:provisional]).to be(false)
    end

    it "levantamento fechado congela as inspeções: a retirada e a inspeção depois do fechamento não mudam o índice" do
      a, b, = item_list
      positive = inspect!(a)
      sample!(positive, "A2", aegypti: 1)
      survey.update!(status: "closed", closed_at: Time.current)
      sleep 0.01 # a inspeção seguinte nasce depois do closed_at
      before = described_class.for(survey)
      expect(before[:strata].first).to include(inspected: 1, positive_households: 1, iip: "100.0")

      withdraw!(positive)
      inspect!(b, hour: 11)
      expect(described_class.for(survey)).to eq(before)
    end

    # Q30 (coordenação): o índice do levantamento fechado é o retrato oficial
    # em closed_at. Pelo caminho real (Liraa::Close e HomeVisits::Withdraw, com
    # o WithdrawInspection): a visita retirada depois do fechamento segue
    # contando, o item fica e inspecionados e positivos não mudam.
    it "Q30: a visita retirada depois do fechamento segue no índice; inspecionados e positivos não mudam" do
      a, b, = item_list
      positive = inspect!(a)
      sample!(positive, "A2", aegypti: 2)
      sample!(inspect!(b), "B", aegypti: 0)
      a.update!(status: "inspected", version: a.version + 1)
      b.update!(status: "inspected", version: b.version + 1)
      expect(VectorControl::Liraa::Close.call(survey: survey, by: endemic_coordinator!)).to be_ok
      before = described_class.for(survey.reload)
      expect(before[:strata].first).to include(inspected: 2, positive_households: 1, positive_containers: 1, iip: "50.0", ib: "50.0")
      sleep 0.01 # a retirada depois do closed_at

      withdrawal = HomeVisits::Withdraw.call(positive.home_visit, by: day.user, expected_state: "recorded",
                                             reason: "registrada no imóvel errado")

      expect(withdrawal).to be_ok
      expect(positive.home_visit.reload.withdrawn_at).to be > survey.closed_at
      expect(a.reload).to have_attributes(status: "inspected", version: 2)
      expect(described_class.for(survey.reload)).to eq(before)
    end
  end
end
