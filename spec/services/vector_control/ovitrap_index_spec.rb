require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6; A-9): IPO, IDO e IDV por bairro
# (o do quarteirão congelado na ovitrampa) e semana epidemiológica do MS
# (Surveillance::EpiWeek, a da instalação da palheta). Examinadas = leituras
# ok e contadas; positivas = ovos > 0; uma casa; nil sem examinadas.
RSpec.describe VectorControl::OvitrapIndex, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:lab) { vector_lab! }
  let(:north) { Neighborhood.create!(name: "Norte #{SecureRandom.hex(3)}", source: "manual") }
  let(:south) { Neighborhood.create!(name: "Sul #{SecureRandom.hex(3)}", source: "manual") }
  let(:week) { Surveillance::EpiWeek.parse("2026-45") }

  # Ovitrampa direto na linha (só leituras coletadas, sem aberta).
  def ovitrap_in(neighborhood)
    block = city_block!(neighborhood: neighborhood, number: SecureRandom.hex(2))
    household = ovitrap_household!(agent, block: block)
    Ovitrap.create!(number: "OV-#{SecureRandom.hex(3)}", household: household, city_block: block, consent_at: Time.current,
                    installed_on: week.starts_on, installed_by_user: agent, origin: "dashboard")
  end

  def reading!(ovitrap, condition:, eggs: nil, installed_on: week.starts_on + 1)
    counted = eggs.nil? ? {} : { egg_count: eggs, counted_at: Time.current, counted_by_user: lab }
    OvitrapReading.create!(ovitrap: ovitrap, installed_on: installed_on, epi_week: described_class.week_of(installed_on),
                           collected_on: installed_on + 5, condition: condition, **counted)
  end

  it "10 examinadas, 4 positivas, 200 ovos → IPO 40.0, IDO 50.0, IDV 20.0" do
    trap = ovitrap_in(north)
    [ 80, 60, 40, 20, 0, 0, 0, 0, 0, 0 ].each { |eggs| reading!(trap, condition: "ok", eggs: eggs) }
    reading!(trap, condition: "ok")
    reading!(trap, condition: "lost")
    reading!(trap, condition: "damaged")
    reading!(trap, condition: "dry")
    reading!(ovitrap_in(south), condition: "ok", eggs: 500)
    reading!(trap, condition: "ok", eggs: 900, installed_on: week.starts_on + 7)

    rows = described_class.for(neighborhood_ids: [ north.id ], epi_weeks: [ week ])
    expect(rows).to eq([ { neighborhood_id: north.id, epi_week: "2026-45", examined: 10, positive: 4, eggs: 200,
                           ipo: 40.0, ido: 50.0, idv: 20.0, lost: 1, damaged: 1 } ])
  end

  it "contagem 0 conta como examinada negativa; uma casa decimal" do
    trap = ovitrap_in(north)
    reading!(trap, condition: "ok", eggs: 0)
    reading!(trap, condition: "ok", eggs: 0)
    reading!(trap, condition: "ok", eggs: 7)
    row = described_class.for(neighborhood_ids: [ north.id ], epi_weeks: [ "2026-45" ]).sole
    expect(row).to include(examined: 3, positive: 1, eggs: 7, ipo: 33.3, ido: 7.0, idv: 2.3)
  end

  it "sem examinadas → nil" do
    reading!(ovitrap_in(north), condition: "damaged")
    rows = described_class.for(neighborhood_ids: [ north.id, south.id ], epi_weeks: [ week ])
    expect(rows).to eq([
      { neighborhood_id: north.id, epi_week: "2026-45", examined: 0, positive: 0, eggs: 0, ipo: nil, ido: nil, idv: nil, lost: 0, damaged: 1 },
      { neighborhood_id: south.id, epi_week: "2026-45", examined: 0, positive: 0, eggs: 0, ipo: nil, ido: nil, idv: nil, lost: 0, damaged: 0 }
    ])
  end

  it "leitura instalada em 2026-01-01 cai em 2025-53" do
    block = city_block!(neighborhood: north, number: "7")
    ovitrap = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), installed_on: Date.new(2026, 1, 1))
    reading = ovitrap_collected!(ovitrap, agent: agent, collected_on: Date.new(2026, 1, 6))
    expect(reading.epi_week).to eq(202_553)
    expect(VectorControl::CountReading.call(reading: reading, egg_count: 12, note: nil, by: lab)).to be_ok

    row = described_class.for(neighborhood_ids: [ north.id ], epi_weeks: [ "2025-53" ]).sole
    expect(row).to include(epi_week: "2025-53", examined: 1, positive: 1, eggs: 12)
    expect(described_class.for(neighborhood_ids: [ north.id ], epi_weeks: [ "2026-01" ]).sole[:examined]).to eq(0)
  end
end
