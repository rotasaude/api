require "rails_helper"

# Módulo 35a (contrato §5; Q8, D-6): os números do ciclo por bairro, pela
# última inspeção válida de cada imóvel no período; pendência com uma casa.
RSpec.describe VectorControl::CycleStats, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:empty) { Neighborhood.create!(name: "Batel #{SecureRandom.hex(3)}", source: "manual") }
  let(:today) { Time.zone.today }
  let(:cycle) { VectorCycle.create!(year: today.year, number: 1, starts_on: today - 10, ends_on: today) }
  let(:day) { home_visit_day!(agent: agent) }

  def household!(micro_area: area) = registry_household_rows!(micro_area, neighborhood_id: neighborhood.id)

  def inspect!(household, situation, at:, recovered: false)
    visit = home_visit!(day: day, micro_area: area, household: household, occurred_at: at,
                        outcome: VectorControl::Catalog::SITUATION_OUTCOME.fetch(situation))
    VectorInspection.create!(home_visit: visit, household: household, activity: "li", work_type: recovered ? "pending" : "routine",
                             situation: situation, educational_action: false, recovered: recovered)
  end

  def at(minutes) = today.in_time_zone.change(hour: 8) + minutes.minutes

  def stats = described_class.for(cycle: cycle, neighborhood_ids: [ neighborhood.id, empty.id ])

  it "40 visitados, 6 com a última do ciclo closed/refused → 15.0" do
    households = Array.new(40) { household! }
    households.each_with_index do |household, index|
      situation = if index < 3 then "closed" elsif index < 6 then "refused" else "worked" end
      inspect!(household, situation, at: at(index))
    end
    inspect!(households[6], "closed", at: at(-30))               # antes, no ciclo: a última é a worked
    inspect!(households[7], "closed", at: (today - 11).in_time_zone.change(hour: 9)) # fora do período
    inspect!(households[8], "worked", at: at(200), recovered: true)
    household!.update_columns(status: "inactive")
    inactive_area = registry_micro_area!(code: "03", team: area.team).tap { |micro_area| micro_area.update!(active: false) }
    household!(micro_area: inactive_area)

    expect(stats).to eq([
      { neighborhood_id: neighborhood.id, to_visit: 40, visited: 40, worked: 34, closed: 3, refused: 3, vacant: 0, recovered: 1,
        pending_percent: 15.0, registered_households: 41 },
      { neighborhood_id: empty.id, to_visit: 0, visited: 0, worked: 0, closed: 0, refused: 0, vacant: 0, recovered: 0,
        pending_percent: nil, registered_households: 0 }
    ])
  end

  it "visita retirada não conta" do
    first = household!
    second = household!
    inspect!(first, "closed", at: at(0))
    gone = inspect!(first, "worked", at: at(10))
    lone = inspect!(second, "vacant", at: at(20))
    [ gone, lone ].each do |inspection|
      inspection.home_visit.update_columns(withdrawn_at: Time.current, withdrawn_by_user_id: agent.id,
                                           withdrawal_reason: "Registrada no domicílio errado")
    end

    expect(stats.first).to include(visited: 1, worked: 0, closed: 1, vacant: 0, pending_percent: 100.0, to_visit: 2)
  end
end
