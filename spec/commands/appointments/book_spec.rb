require "rails_helper"

# ADR 0029 §4.3: a vaga tem de existir no cálculo; o cidadão não pode ter
# outro horário ativo sobreposto; a EXCLUDE decide a corrida (slot_taken).
RSpec.describe Appointments::Book do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:reception) { staff_with("recepcao-book@cidade.gov.br", "citizen_verifier") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:medica) { AppointmentType.find_by!(key: "consulta_medica") }
  let(:day) { Time.zone.today + 5 }
  let!(:shift) { shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 10)) }
  let(:request) { triage_request!(citizen, unit: unit) }

  def book(req = request, at: shift.starts_at, type: medica, professional: link.professional)
    described_class.call(request: req, professional: professional, starts_at: at.iso8601, type: type, by: reception)
  end

  it "marca a vaga: slot com profissional, tipo, fim e turno; pedido scheduled; evento só de ids" do
    appointment = book.payload[:appointment]
    expect(appointment).to have_attributes(booking_kind: "slot", professional_id: link.professional_id, shift_id: shift.id,
                                           appointment_type_key: "consulta_medica", scheduled_at: shift.starts_at,
                                           ends_at: shift.starts_at + 20.minutes, status: "scheduled",
                                           health_unit_id: unit.id)
    expect(request.reload.status).to eq("scheduled")
    expect(DomainEvent.where(name: "appointment.booked").sole.payload)
      .to eq("appointment_id" => appointment.id, "request_id" => request.id, "booking_kind" => "slot")
  end

  it "com menos de 48h nasce confirmado" do
    near = shift!(link, starts_at: 1.day.from_now.change(min: 0), ends_at: 1.day.from_now.change(min: 0) + 1.hour)
    expect(book(at: near.starts_at).payload[:appointment].status).to eq("confirmed")
  end

  it "fora da grade é slot_unavailable; tipo que o CBO não atende é type_not_served; passado é invalid_time" do
    expect(book(at: shift.starts_at + 5.minutes).reason).to eq(:slot_unavailable)
    expect(book(type: AppointmentType.find_by!(key: "consulta_enfermagem")).reason).to eq(:type_not_served)
    expect(book(at: 1.hour.ago).reason).to eq(:invalid_time)
    expect(described_class.call(request: request, professional: nil, starts_at: shift.starts_at.iso8601, type: medica,
                                by: reception).reason).to eq(:slot_unavailable)
  end

  it "pedido sem unidade é wrong_unit; pedido encerrado é request_not_open" do
    expect(book(triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: nil)).reason).to eq(:wrong_unit)
    AppointmentRequests::Lifecycle.close!(request, reason: "dismissed", by: reception, dismiss_reason: "cidadão mudou de cidade")
    expect(book.reason).to eq(:request_not_open)
  end

  it "cidadão com outro horário ativo sobreposto (inclusive legacy de 15 min) é citizen_busy" do
    other = triage_request!(citizen, unit: unit, type_key: "retorno")
    Appointment.create!(request: other, citizen: citizen, health_unit: unit, scheduled_at: shift.starts_at + 10.minutes,
                        scheduled_by_user: reception, status: "confirmed", confirmed_at: Time.current)
    expect(book.reason).to eq(:citizen_busy)
    # o legacy das 08:10 ocupa até 08:25 (LEGACY_SPAN): a vaga das 08:20 também colide
    expect(book(at: shift.starts_at + 20.minutes).reason).to eq(:citizen_busy)
    expect(book(at: shift.starts_at + 40.minutes)).to be_ok
  end

  it "o horário vivo do próprio pedido não conta como ocupado: o legacy vira slot sobreposto" do
    legacy = Appointment.create!(request: request, citizen: citizen, health_unit: unit,
                                 scheduled_at: shift.starts_at + 50.minutes, scheduled_by_user: reception,
                                 status: "confirmed", confirmed_at: Time.current)
    request.update!(status: "scheduled")
    moved = book(at: shift.starts_at + 40.minutes).payload[:appointment]
    expect(moved).to have_attributes(booking_kind: "slot", moved_from_appointment_id: legacy.id)
    expect(legacy.reload.status).to eq("moved")
  end

  it "violação da trava (corrida) vira slot_taken, sem exceção" do
    rival = triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit)
    slot = Scheduling::Availability.for(unit: unit, from: day, to: day, appointment_type: medica).first
    appointment_row!(rival, shift, starts_at: shift.starts_at)
    allow(Scheduling::Availability).to receive(:for).and_return([ slot ])
    expect(book.reason).to eq(:slot_taken)
    expect(request.reload.status).to eq("open")
  end

  it "dentro de uma transação de quem chama, a trava vira slot_taken e a transação de fora segue usável" do
    rival = triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit)
    slot = Scheduling::Availability.for(unit: unit, from: day, to: day, appointment_type: medica).first
    appointment_row!(rival, shift, starts_at: shift.starts_at)
    allow(Scheduling::Availability).to receive(:for).and_return([ slot ])
    ApplicationRecord.transaction do
      expect(book.reason).to eq(:slot_taken)
      # sem savepoint próprio a transação estaria abortada (PG::InFailedSqlTransaction)
      expect(AppointmentRequest.find(request.id).status).to eq("open")
    end
  end

  it "cidadão com horário de vaga sobreposto em OUTRA unidade é citizen_busy" do
    other_unit = create_unit("UBS Norte")
    other_link = doctor_link!(other_unit)
    other_shift = shift!(other_link, starts_at: shift.starts_at, ends_at: shift.ends_at)
    appointment_row!(triage_request!(citizen, unit: other_unit, type_key: "retorno"), other_shift,
                     starts_at: shift.starts_at + 10.minutes)
    expect(book.reason).to eq(:citizen_busy)
  end

  it "pedido reaberto marcado de novo perde o reopened_reason" do
    request.update!(reopened_reason: "no_show")
    expect(book).to be_ok
    expect(request.reload).to have_attributes(status: "scheduled", reopened_reason: nil)
  end

  it "remarcação pela recepção: o horário vivo vira moved e o novo aponta para ele" do
    first = book.payload[:appointment]
    second = book(at: shift.starts_at + 40.minutes).payload[:appointment]
    expect(first.reload).to have_attributes(status: "moved")
    expect(second).to have_attributes(moved_from_appointment_id: first.id, status: "scheduled")
    expect(DomainEvent.where(name: "appointment.moved").sole.payload)
      .to include("from_appointment_id" => first.id, "to_appointment_id" => second.id)
  end

  it "unidade desativada entre a leitura e a transação: invalid_unit" do
    request # o pedido nasce antes do stub de transação
    deactivate_before_transaction(unit)
    expect(book.reason).to eq(:invalid_unit)
  end
end
