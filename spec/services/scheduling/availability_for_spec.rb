require "rails_helper"

# A carga do banco que alimenta o cálculo puro (ADR 0029 §4.1): só turnos não
# cancelados da unidade; horários ativos do profissional em QUALQUER unidade
# ocupam; tipo desativado não tem vaga; dia sem turno é legacy.
RSpec.describe Scheduling::Availability, ".for" do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UBS Sul") }
  let(:link) { doctor_link!(unit) }
  let(:day) { Time.zone.today + 2 }
  let(:medica) { AppointmentType.find_by!(key: "consulta_medica") }
  def hours(slots) = slots.map { |s| s.starts_at.strftime("%H:%M") }
  def citizen!(cpf, phone) = Citizen.create!(cpf: cpf, phone: phone)

  it "vagas do turno, sem as ocupadas (inclusive em outra unidade) e sem turno cancelado" do
    shift = shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 9))
    shift!(link, starts_at: (day + 1).in_time_zone.change(hour: 8), ends_at: (day + 1).in_time_zone.change(hour: 9))
      .update!(cancelled_at: Time.current, cancelled_by_user: link.started_by_user, cancel_reason: "troca")
    appointment_row!(triage_request!(citizen!("52998224725", "+5541998765432"), unit: unit), shift,
                     starts_at: shift.starts_at + 20.minutes)

    slots = described_class.for(unit: unit, from: day, to: day + 1, appointment_type: medica)
    expect(hours(slots)).to eq([ "08:00", "08:40" ])
    expect(slots.first).to have_attributes(professional_id: link.professional_id, shift_id: shift.id)

    # A mesma médica também atende na UBS Sul, no turno anterior (07:00–08:00;
    # turnos dela nunca se sobrepõem). Um encaixe lá às 07:50 vai até 08:10 e
    # ocupa a vaga das 08:00 daqui.
    other_link = ProfessionalLink.create!(professional: link.professional, health_unit: other_unit, cbo_code: "225125",
                                          started_at: Time.current, started_by_user: link.started_by_user)
    other_shift = shift!(other_link, starts_at: day.in_time_zone.change(hour: 7), ends_at: day.in_time_zone.change(hour: 8))
    appointment_row!(triage_request!(citizen!("11144477735", "+5541911112222"), unit: other_unit), other_shift,
                     starts_at: day.in_time_zone.change(hour: 7, min: 50), kind: "fit_in",
                     reason: "encaixe pedido pela equipe")

    expect(hours(described_class.for(unit: unit, from: day, to: day + 1, appointment_type: medica))).to eq([ "08:40" ])
    # Na UBS Sul (07:00, 07:20, 07:40) some a que cruza o encaixe.
    expect(hours(described_class.for(unit: other_unit, from: day, to: day, appointment_type: medica)))
      .to eq([ "07:00", "07:20" ])
  end

  it "horário que não está ativo não ocupa a vaga" do
    shift = shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 8, min: 40))
    appointment_row!(triage_request!(citizen!("52998224725", "+5541998765432"), unit: unit), shift,
                     starts_at: shift.starts_at).update!(status: "cancelled_by_citizen", ended_at: Time.current,
                                                         cancel_reason: "não poderá comparecer")
    expect(hours(described_class.for(unit: unit, from: day, to: day, appointment_type: medica)))
      .to eq([ "08:00", "08:20" ])
  end

  it "tipo desativado: nenhuma vaga" do
    shift!(link, starts_at: day.in_time_zone.change(hour: 8))
    medica.update!(active: false)
    expect(described_class.for(unit: unit, from: day, to: day, appointment_type: medica)).to eq([])
  end

  it "tipo padrão do vínculo desativado depois: cai na base pelo CBO" do
    type_row!("consulta_breve", cbo: [ "2251" ], minutes: 10)
    link.update_columns(default_appointment_type_key: "consulta_breve")
    shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 8, min: 40))
    AppointmentType.find_by!(key: "consulta_breve").update!(active: false)
    expect(hours(described_class.for(unit: unit, from: day, to: day, appointment_type: medica)))
      .to eq([ "08:00", "08:20" ])
  end

  it "faixas do modelo ligado ao turno" do
    template = ScheduleTemplate.create!(name: "Manhã", blocks: [
      { "starts" => "08:00", "ends" => "08:30", "kind" => "walk_in" },
      { "starts" => "08:30", "ends" => "09:10", "kind" => "bookable", "appointment_type_key" => "consulta_medica" }
    ])
    shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 12), template: template)
    expect(hours(described_class.for(unit: unit, from: day, to: day, appointment_type: medica)))
      .to eq([ "08:30", "08:50" ])
  end

  it "transição: dia com turno não cancelado da unidade usa vagas; os outros são legacy" do
    shift!(link, starts_at: day.in_time_zone.change(hour: 22), ends_at: (day + 1).in_time_zone.change(hour: 6))
    cancelled = shift!(link, starts_at: (day + 3).in_time_zone.change(hour: 8))
    cancelled.update!(cancelled_at: Time.current, cancelled_by_user: link.started_by_user, cancel_reason: "troca")
    expect(Scheduling::Transition.legacy_days(unit.id, day - 1, day + 3)).to eq([ day - 1, day + 2, day + 3 ])
    expect(Scheduling::Transition.slots_day?(unit.id, day + 1)).to be(true)
    expect(Scheduling::Transition.slots_day?(other_unit.id, day)).to be(false)
  end

  it "transição: turno que termina à meia-noite não conta no dia seguinte" do
    shift!(link, starts_at: day.in_time_zone.change(hour: 20), ends_at: (day + 1).in_time_zone.beginning_of_day)
    expect(Scheduling::Transition.legacy_days(unit.id, day, day + 1)).to eq([ day + 1 ])
  end
end

RSpec.describe Scheduling::DateRange, ".parse" do
  it "inclusivo, com padrão e teto" do
    today = Time.zone.today
    expect(described_class.parse(nil, nil, default_days: 7, max_days: 14)).to eq(today..today + 6)
    expect(described_class.parse("2026-10-10", nil, default_days: 7, max_days: 14))
      .to eq(Date.new(2026, 10, 10)..Date.new(2026, 10, 16))
    expect(described_class.parse("2026-10-10", "2026-10-23", default_days: 7, max_days: 14))
      .to eq(Date.new(2026, 10, 10)..Date.new(2026, 10, 23))
    expect(described_class.parse("2026-10-10", "2026-10-24", default_days: 7, max_days: 14)).to be_nil
    expect(described_class.parse("2026-10-10", "2026-10-09", default_days: 7, max_days: 14)).to be_nil
    expect(described_class.parse("ontem", nil, default_days: 7, max_days: 14)).to be_nil
  end
end
