require "rails_helper"

# ADR 0030 (spec §4; contrato §9 do módulo 18): três grupos na fila do
# profissional — (1) escuta concluída same_day, por cor (red, yellow, green,
# blue) e chegada; (2) quem não exige escuta pelo escopo, na ordem de hoje;
# (3) quem ainda aguarda a escuta (em curso e abandonada contam), na ordem de
# hoje, por último. Ninguém é pulado: o chamar próximo segue a mesma ordem.
# O grupo 3 só existe com protocolo de acolhimento ativo na cidade (spec
# §11.4): sem ele, a escuta concluída vem antes e o resto segue o módulo 13.
RSpec.describe Attendances::UnitQueue, "com escuta" do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:doctor) { screener!(unit, cbo: "225125") }
  let(:t0) { Time.zone.parse("2026-10-07 08:00") }

  def screened!(n, color, at:)
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(n), checked_in_at: at)
    screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: screening, revision_params: revision_params(final_color: color),
                              destination: "same_day", destination_params: {}, by: nurse)
    attendance
  end

  def call_order
    ids = []
    while (r = Attendances::CallNext.call(health_unit_id: unit.id, by: doctor)).ok?
      ids << r.payload[:attendance].id
    end
    expect(r.reason).to eq(:queue_empty)
    ids
  end

  it "com protocolo ativo: cor antes de chegada; depois quem não exige escuta; quem aguarda a escuta por último" do
    acolhimento!
    plain_urgent = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
    plain_urgent.triage.update_columns(priority: 1)
    plain_later = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0 + 1.minute)
    plain_later.triage.update_columns(priority: 9)
    green = screened!(3, "green", at: t0 + 2.minutes)
    red = screened!(4, "red", at: t0 + 30.minutes)
    yellow_early = screened!(5, "yellow", at: t0 + 3.minutes)
    yellow_late = screened!(6, "yellow", at: t0 + 10.minutes)
    blue = screened!(7, "blue", at: t0 + 1.minute)
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(8), checked_in_at: t0 + 40.minutes)

    expected = [ red.id, yellow_early.id, yellow_late.id, green.id, blue.id, scheduled.id, plain_urgent.id, plain_later.id ]
    expect(described_class.waiting(unit.id).map(&:id)).to eq(expected)
    expect(ApplicationRecord.transaction { described_class.lock_next_waiting(unit.id) }.id).to eq(red.id)
    expect(call_order).to eq(expected)
  end

  it "sem protocolo ativo: escuta concluída por cor primeiro; o resto na ordem do módulo 13, sem grupo 3" do
    plain_urgent = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0 + 5.minutes)
    plain_urgent.triage.update_columns(priority: 1)
    plain_later = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0 + 1.minute)
    plain_later.triage.update_columns(priority: 9)
    green = screened!(3, "green", at: t0 + 2.minutes)
    red = screened!(4, "red", at: t0 + 30.minutes)
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(5), checked_in_at: t0)
    scheduled.appointment.request.root_triage.update_columns(priority: 5)

    # a chegada urgente (walk-in sem escuta) não afunda atrás do horário, e
    # ninguém vem marcado como aguardando acolhimento.
    expected = [ red.id, green.id, plain_urgent.id, scheduled.id, plain_later.id ]
    expect(described_class.waiting(unit.id).map(&:id)).to eq(expected)
    expect(Attendance.where(id: expected).map { |a| Screenings::Queue.awaiting?(a) }).to all(be(false))
    expect(call_order).to eq(expected)
  end

  it "escopo all: o horário sem escuta passa a aguardar a escuta (grupo 3)" do
    acolhimento!
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
    walk_in = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0 + 1.minute)
    walk_in.triage.update_columns(priority: 1)
    expect(described_class.waiting(unit.id).map(&:id)).to eq([ scheduled.id, walk_in.id ])

    unit.update!(screening_scope: "all")
    scheduled.appointment.request.root_triage&.update_columns(priority: 5)
    expect(described_class.waiting(unit.id).map(&:id)).to eq([ walk_in.id, scheduled.id ])
  end

  it "reavaliar muda a cor e a posição" do
    green = screened!(1, "green", at: t0)
    yellow = screened!(2, "yellow", at: t0 + 5.minutes)
    Screenings::Reassess.call(screening: green.screening, by: nurse, revision_params: revision_params(final_color: "red"))
    expect(described_class.waiting(unit.id).map(&:id)).to eq([ green.id, yellow.id ])
  end

  it "chamar próximo chama quem está em escuta e a escuta vira abandonada" do
    in_listening = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
    screening = Screenings::Start.call(attendance: in_listening, by: nurse).payload[:screening]

    result = Attendances::CallNext.call(health_unit_id: unit.id, by: doctor)
    expect(result).to be_ok
    expect(result.payload[:attendance].id).to eq(in_listening.id)
    expect(screening.reload.status).to eq("abandoned")
  end
end
