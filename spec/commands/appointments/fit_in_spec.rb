# spec/commands/appointments/fit_in_spec.rb
require "rails_helper"

# ADR 0029 §4.3: encaixe é horário extra DENTRO do turno, com justificativa,
# contado contra o limite do turno; pode sobrepor vaga ocupada.
RSpec.describe Appointments::FitIn do
  before do
    Current.city = TEST_CITY_A
    ensure_appointment_types!
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:reception) { staff_with("recepcao-encaixe@cidade.gov.br", "citizen_verifier") }
  let(:medica) { AppointmentType.find_by!(key: "consulta_medica") }
  let(:day) { Time.zone.today + 5 }
  let(:shift) { shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 10)) }
  let(:reason) { "gestante com sangramento leve" }
  let(:cpfs) { %w[52998224725 11144477735 39053344705 87748248800] }
  def citizen(i) = Citizen.create!(cpf: cpfs[i], phone: "+55419#{format('%08d', 30_000_000 + i)}")
  let(:requests) { Hash.new { |h, k| h[k] = triage_request!(citizen(k), unit: unit) } }

  def fit_in(req, at: shift.starts_at + 10.minutes, why: reason, type: medica, on: shift)
    described_class.call(request: req, professional: link.professional, shift: on, starts_at: at.iso8601, type: type,
                         reason: why, by: reception)
  end

  it "grava fit_in sobre vaga ocupada, com fim pela duração do tipo; eventos sem a justificativa" do
    appointment_row!(requests[1], shift, starts_at: shift.starts_at)
    appointment = fit_in(requests[0]).payload[:appointment]
    expect(appointment).to have_attributes(booking_kind: "fit_in", fit_in_reason: reason, shift_id: shift.id,
                                           scheduled_at: shift.starts_at + 10.minutes,
                                           ends_at: shift.starts_at + 10.minutes + medica.duration_minutes.minutes)
    expect(requests[0].reload.status).to eq("scheduled")
    events = DomainEvent.where(name: %w[appointment.booked appointment.fit_in_created]).pluck(:name, :payload).to_h
    expect(events["appointment.fit_in_created"]).to eq("appointment_id" => appointment.id, "shift_id" => shift.id)
    expect(events["appointment.booked"]).to include("booking_kind" => "fit_in", "appointment_id" => appointment.id)
    expect(events.values.to_json).not_to include("gestante")
  end

  it "conta contra o limite padrão da cidade (2) ou o do modelo; o próprio pedido remarcado não conta" do
    first = fit_in(requests[0]).payload[:appointment]
    fit_in(requests[1], at: shift.starts_at + 40.minutes)
    expect(fit_in(requests[2], at: shift.starts_at + 70.minutes).reason).to eq(:fit_in_limit)
    expect(fit_in(requests[0], at: shift.starts_at + 70.minutes)).to be_ok
    expect(first.reload.status).to eq("moved")

    template = ScheduleTemplate.create!(name: "Sem encaixe", fit_in_limit: 0,
                                        blocks: [ { "starts" => "08:00", "ends" => "10:00", "kind" => "blocked" } ])
    other = shift!(link, starts_at: (day + 1).in_time_zone.change(hour: 8), template: template)
    expect(fit_in(requests[3], at: other.starts_at + 10.minutes, on: other).reason).to eq(:fit_in_limit)
  end

  # Só o horário VIVO do pedido (o que Placement.create! move) sai da conta. Um
  # encaixe do pedido já com check-in segue ocupando o turno: se o pedido ainda
  # estiver marcável, um segundo encaixe dele não pode levar o turno a limite+1.
  # (O CheckIn real fecha o pedido; o estado aqui é montado direto para provar
  # a conta, sem depender desse fechamento.)
  it "encaixe do próprio pedido já com check-in continua contando contra o limite" do
    own = fit_in(requests[0]).payload[:appointment]
    own.update!(status: "confirmed", confirmed_at: Time.current)
    own.update!(status: "checked_in", ended_at: Time.current)
    expect(requests[0].reload.status).to eq("scheduled")
    expect(fit_in(requests[1], at: shift.starts_at + 40.minutes)).to be_ok
    expect(fit_in(requests[0], at: shift.starts_at + 70.minutes).reason).to eq(:fit_in_limit)
    expect(Appointment.where(shift_id: shift.id, booking_kind: "fit_in", status: Appointment::ACTIVE).count).to eq(2)
  end

  it "encaixe cancelado pelo cidadão não conta contra o limite" do
    fit_in(requests[0]).payload[:appointment].update!(status: "cancelled_by_citizen", ended_at: Time.current,
                                                      cancel_reason: "não poderei comparecer")
    fit_in(requests[1], at: shift.starts_at + 40.minutes)
    expect(fit_in(requests[2], at: shift.starts_at + 70.minutes)).to be_ok
  end

  it "limite do modelo vale mesmo com o modelo inativo" do
    template = ScheduleTemplate.create!(name: "Um encaixe", fit_in_limit: 1,
                                        blocks: [ { "starts" => "08:00", "ends" => "10:00", "kind" => "blocked" } ])
    other = shift!(link, starts_at: (day + 1).in_time_zone.change(hour: 8), template: template)
    template.update!(active: false)
    expect(fit_in(requests[0], at: other.starts_at + 10.minutes, on: other)).to be_ok
    expect(fit_in(requests[1], at: other.starts_at + 50.minutes, on: other).reason).to eq(:fit_in_limit)
  end

  it "limite da cidade vem do perfil" do
    (CityProfile.current || CityProfile.create!(name: "Cidade")).update!(default_fit_in_limit: 0)
    expect(fit_in(requests[0]).reason).to eq(:fit_in_limit)
  end

  it "recusas: justificativa curta, fora do turno, turno cancelado, de outro profissional, tipo não servido, pedido sem unidade" do
    expect(fit_in(requests[0], why: "urgente").reason).to eq(:invalid_reason)
    expect(fit_in(requests[0], why: "   urgente    ").reason).to eq(:invalid_reason)
    expect(fit_in(requests[0], at: shift.ends_at - 10.minutes).reason).to eq(:outside_shift)
    expect(fit_in(requests[0], at: shift.starts_at - 10.minutes).reason).to eq(:outside_shift)
    expect(fit_in(requests[0],
                  type: AppointmentType.find_by!(key: "consulta_enfermagem")).reason).to eq(:type_not_served)
    expect(described_class.call(request: requests[0], professional: doctor_link!(unit).professional, shift: shift,
                                starts_at: (shift.starts_at + 10.minutes).iso8601, type: medica, reason: reason,
                                by: reception).reason).to eq(:outside_shift)
    expect(fit_in(triage_request!(citizen(3), unit: nil)).reason).to eq(:wrong_unit)
    shift.update!(cancelled_at: Time.current, cancelled_by_user: reception, cancel_reason: "troca")
    expect(fit_in(requests[0]).reason).to eq(:outside_shift)
    expect(Appointment.where(booking_kind: "fit_in")).to be_empty
  end

  it "recusas: horário passado ou inválido, cidadão ocupado, pedido fechado, unidade inativa" do
    expect(fit_in(requests[0], at: 1.hour.ago).reason).to eq(:invalid_time)
    expect(described_class.call(request: requests[0], professional: link.professional, shift: shift, starts_at: "x",
                                type: medica, reason: reason, by: reception).reason).to eq(:invalid_time)

    busy = triage_request!(citizen(1), unit: unit, type_key: "consulta_enfermagem")
    appointment_row!(busy, shift, starts_at: shift.starts_at + 20.minutes)
    expect(fit_in(triage_request!(Citizen.find_by!(cpf: cpfs[1]), unit: unit)).reason).to eq(:citizen_busy)

    requests[2].update!(status: "closed", closed_reason: "citizen_cancelled", closed_at: Time.current)
    expect(fit_in(requests[2]).reason).to eq(:request_not_open)

    unit.update!(active: false)
    expect(fit_in(requests[0]).reason).to eq(:invalid_unit)
  end

  it "turno de outra unidade: outside_shift" do
    other_unit = create_unit("UBS Sul")
    expect(fit_in(triage_request!(citizen(1), unit: other_unit)).reason).to eq(:outside_shift)
  end
end
