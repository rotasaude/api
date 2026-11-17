require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6, §11, §17; Q9; A-8): a contagem
# de ovos pela coordenação ou pelo vector_lab, só em palheta coletada boa; a
# correção exige nota nova (comparada em texto claro: a cifra muda a cada
# gravação) e o evento leva corrected. Contagem ≥ ovitrap_alert_eggs abre a
# tarefa de intensificação com o raio de ovitrap_radius_rings, salvo já haver
# uma aberta da ovitrampa.
RSpec.describe VectorControl::CountReading, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:lab) { vector_lab! }
  let(:north) { Neighborhood.create!(name: "Norte #{SecureRandom.hex(3)}", source: "manual") }
  let!(:a) { city_block!(neighborhood: north, number: "1") }
  let!(:b) { city_block!(neighborhood: north, number: "2") }
  let!(:c) { city_block!(neighborhood: north, number: "3") }
  let(:household) { ovitrap_household!(agent, block: a) }
  let(:today) { Time.zone.today }
  let(:ovitrap) { ovitrap_installed!(agent: agent, household: household, installed_on: today - 15) }

  def link!(x, y)
    first, second = [ x, y ].sort_by(&:id)
    CityBlockNeighbor.create!(city_block: first, neighbor_block: second)
  end

  before do
    link!(a, b)
    link!(b, c)
  end

  # Três palhetas coletadas em sequência (dias −10, −5 e hoje).
  def readings
    @readings ||= [ today - 10, today - 5, today ].map { |day| ovitrap_collected!(ovitrap, agent: agent, collected_on: day) }
  end

  def count(reading, eggs, note: nil, by: lab) = described_class.call(reading: reading, egg_count: eggs, note: note, by: by)
  def refusal(result) = [ result.reason, result.details ]
  def opened = DomainEvent.where(name: "vector_task.opened")

  it "99 não abre tarefa; 100 abre com os vizinhos de 1 anel" do
    first, second = readings
    expect(count(first, 99)).to be_ok
    expect(VectorTask.count).to eq(0)
    expect(first.reload).to have_attributes(egg_count: 99, counted_by_user_id: lab.id, count_note: nil, version: 3)

    result = count(second, 100)
    task = result.payload[:task]
    expect(task).to have_attributes(kind: "ovitrap_intensification", state: "open", ovitrap_id: ovitrap.id, ovitrap_reading_id: second.id)
    expect(task.suggested_block_ids).to contain_exactly(a.id, b.id)
    expect(opened.sole.payload).to eq("vector_task_id" => task.id)
    expect(DomainEvent.where(name: "ovitrap_reading.counted").map(&:payload)).to contain_exactly(
      { "ovitrap_reading_id" => first.id, "user_id" => lab.id, "corrected" => false },
      { "ovitrap_reading_id" => second.id, "user_id" => lab.id, "corrected" => false }
    )
  end

  it "segunda contagem ≥ 100 com tarefa aberta não abre outra" do
    _, second, third = readings
    task = count(second, 120).payload[:task]
    result = count(third, 300, by: endemic_coordinator!)
    expect(result).to be_ok
    expect(result.payload[:task]).to be_nil
    expect(VectorTask.sole.id).to eq(task.id)
    expect(opened.count).to eq(1)

    task.update!(state: "done", closed_by_user: endemic_coordinator!, closed_note: "Quarteirões vistoriados")
    fixed = count(third, 310, note: "Recontagem na lupa estereoscópica")
    expect(fixed.payload[:task]).to have_attributes(ovitrap_reading_id: third.id, state: "open")
    expect(opened.count).to eq(2)
  end

  it "palheta damaged → reading_not_countable; aberta → reading_not_countable; agente → missing_role" do
    damaged = ovitrap_collected!(ovitrap, agent: agent, collected_on: today - 10, condition: "damaged")
    expect(count(damaged, 3).reason).to eq(:reading_not_countable)
    open = ovitrap.readings.open_readings.sole
    expect(count(open, 3).reason).to eq(:reading_not_countable)
    expect(count(open, 3, by: agent).reason).to eq(:missing_role)
    expect(refusal(count(open, 10_000))).to eq([ :invalid_request, { path: "egg_count" } ])
    expect(refusal(count(open, "12"))).to eq([ :invalid_request, { path: "egg_count" } ])
  end

  it "correção sem nota → invalid_request path count_note; com nota → corrected: true no evento; nota repetida ou só a nota → recusa" do
    first = readings.first
    expect(refusal(count(first, 0, note: "Contagem inicial anotada"))).to eq([ :invalid_request, { path: "count_note" } ])
    expect(count(first, 0)).to be_ok

    expect(refusal(count(first, 4))).to eq([ :invalid_request, { path: "count_note" } ])
    expect(refusal(count(first, 4, note: "curta"))).to eq([ :invalid_request, { path: "count_note" } ])
    expect(refusal(count(first, 4, note: "x" * 501))).to eq([ :invalid_request, { path: "count_note" } ])
    expect(count(first, 4, note: "  Recontagem com lupa estereoscópica  ")).to be_ok
    expect(first.reload).to have_attributes(egg_count: 4, count_note: "Recontagem com lupa estereoscópica")
    event = DomainEvent.where(name: "ovitrap_reading.counted").order(:created_at, :id).last
    expect(event.payload).to eq("ovitrap_reading_id" => first.id, "user_id" => lab.id, "corrected" => true)

    expect(refusal(count(first, 5, note: "Recontagem com lupa estereoscópica"))).to eq([ :invalid_request, { path: "count_note" } ])
    expect(refusal(count(first, 4, note: "Só a nota mudou nesta correção"))).to eq([ :invalid_request, { path: "egg_count" } ])
    expect(first.reload).to have_attributes(egg_count: 4, version: 4)
  end
end
