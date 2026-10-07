require "rails_helper"

# F-13.4: a fila da unidade ordena pela prioridade da triagem raiz (a própria,
# ou a do pedido do horário), sem prioridade por último, depois pela chegada e,
# no empate, pelo id. "Chamar próximo" segue exatamente a mesma ordem.
# Desde o módulo 18 (contrato §9; spec §11.4): esta é a ordem da cidade sem
# protocolo de acolhimento ativo — com ele, ver unit_queue_screening_spec.
RSpec.describe Attendances::UnitQueue do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, unit) }
  after { Current.reset; Rails.cache.clear }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:t0) { Time.zone.parse("2026-10-01 10:00") }
  let(:cpfs) { %w[52998224725 11144477735 93541134780 39053344705 71428793860 24843803483] }

  def citizen(i) = Citizen.create!(cpf: cpfs.fetch(i), phone: "+55419#{format('%08d', 10_000_000 + i)}")

  # Atendimento nascido de triagem, com a prioridade dada e check-in em `at`.
  def from_triage(i, priority:, at:, in_unit: unit)
    travel_to(at) do
      waiting_attendance(citizen(i), unit: in_unit, by: reception).tap { |a| a.triage.update_columns(priority: priority) }
    end
  end

  # Atendimento nascido de horário: a prioridade vem da triagem raiz do pedido.
  def from_slot(i, root_priority:, at:)
    c = citizen(i)
    appt = travel_to(at - 1.hour) do
      first = in_care!(waiting_attendance(c, unit: unit, by: reception), by: doctor)
      first.triage.update_columns(priority: root_priority)
      req = Attendances::Close.call(attendance: first, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                    by: doctor).payload.fetch(:appointment_request)
      Appointments::Schedule.call(request: req, scheduled_at: (at + 30.minutes).iso8601, health_unit_id: unit.id,
                                  by: reception).payload.fetch(:appointment)
    end
    travel_to(at) do
      Attendances::CheckInByException.call(cpf: c.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                           reason: "cidadão sem celular", by: reception).payload.fetch(:attendance)
    end
  end

  def call_order
    ids = []
    while (r = Attendances::CallNext.call(health_unit_id: unit.id, by: doctor)).ok?
      ids << r.payload[:attendance].id
    end
    expect(r.reason).to eq(:queue_empty)
    ids
  end

  it "fila mista: o horário entra na posição da prioridade da sua triagem raiz; sem prioridade vai por último" do
    urgent = from_triage(0, priority: 1, at: t0 + 30.minutes)
    no_priority = from_triage(1, priority: nil, at: t0)
    calm = from_triage(2, priority: 9, at: t0 + 1.minute)
    slot = from_slot(3, root_priority: 2, at: t0 + 40.minutes)

    expected = [ urgent.id, slot.id, calm.id, no_priority.id ]
    expect(described_class.waiting(unit.id).map(&:id)).to eq(expected)
    expect(travel_to(t0 + 2.hours) { call_order }).to eq(expected)
  end

  it "mesma prioridade e mesma chegada: desempata pelo id, na fila e no chamar próximo" do
    tied = Array.new(3) { |i| from_triage(i, priority: 5, at: t0) }

    expected = tied.map(&:id).sort
    expect(described_class.waiting(unit.id).map(&:id)).to eq(expected)
    expect(call_order).to eq(expected)
  end

  it "a fila é da unidade: atendimento de outra unidade nunca aparece nem é chamado" do
    mine = from_triage(0, priority: 9, at: t0)
    from_triage(1, priority: 1, at: t0, in_unit: other_unit)

    expect(described_class.waiting(unit.id).map(&:id)).to eq([ mine.id ])
    expect(call_order).to eq([ mine.id ])
    expect(described_class.waiting(other_unit.id).size).to eq(1)
  end
end
