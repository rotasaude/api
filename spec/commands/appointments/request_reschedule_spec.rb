require "rails_helper"

# ADR 0029 §6 (spec §9 "Cidadão: reschedule"): motivo, período, contagem,
# prazo mantido; recusas nas bordas; nota nunca em evento.
RSpec.describe Appointments::RequestReschedule do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:shift) { shift!(doctor_link!(unit), starts_at: 4.days.from_now.change(hour: 8)) }
  let(:request) { triage_request!(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit, due_on: Time.zone.today + 12) }
  let(:appointment) do
    appointment_row!(request, shift, starts_at: shift.starts_at).tap { request.update!(status: "scheduled") }
  end

  def ask(appt = appointment, reason: "work", note: "entro às 7h no serviço", period: "afternoon")
    described_class.call(appointment: appt, reason_code: reason, note: note, preferred_period: period)
  end

  it "cancela com a frase fixa, devolve o pedido marcado à fila e mantém o prazo" do
    expect(ask).to be_ok
    expect(appointment.reload).to have_attributes(status: "cancelled_by_citizen", reschedule_requested: true,
                                                  cancel_reason: "Remarcação pedida pelo cidadão")
    expect(request.reload).to have_attributes(status: "open", reopened_reason: "citizen_reschedule",
                                              reschedule_reason_code: "work", reschedule_note: "entro às 7h no serviço",
                                              preferred_period: "afternoon", reschedule_count: 1,
                                              due_on: Time.zone.today + 12)
    payload = DomainEvent.where(name: "appointment.reschedule_requested").sole.payload
    expect(payload).to eq("appointment_id" => appointment.id, "request_id" => request.id)
  end

  it "conta cada pedido de remarcação" do
    ask
    second = appointment_row!(request.reload, shift, starts_at: shift.starts_at + 40.minutes)
    request.update!(status: "scheduled")
    described_class.call(appointment: second, reason_code: "transport", note: nil, preferred_period: "any")
    expect(request.reload).to have_attributes(reschedule_count: 2, reschedule_reason_code: "transport", reschedule_note: nil)
  end

  it "aceita nota de exatamente 200 caracteres" do
    expect(ask(note: "x" * 200)).to be_ok
    expect(request.reload.reschedule_note.length).to eq(200)
  end

  {
    { reason: "ferias" } => :invalid_reason_code, { period: "noite" } => :invalid_period,
    { note: "x" * 201 } => :note_too_long
  }.each do |args, reason|
    it("recusa #{args.keys.first} inválido com #{reason} sem mexer no horário") do
      expect(ask(**args).reason).to eq(reason)
      expect(appointment.reload.status).to eq("confirmed")
    end
  end

  it "depois do início, já cancelado, ou duas vezes: not_reschedulable" do
    ask
    expect(ask(appointment.reload).reason).to eq(:not_reschedulable)
    expect(request.reload.reschedule_count).to eq(1)
    other = appointment_row!(triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit),
                             shift, starts_at: shift.starts_at + 20.minutes)
    travel_to(other.scheduled_at + 1.minute) { expect(ask(other).reason).to eq(:not_reschedulable) }
    expect(other.reload.status).to eq("confirmed")
  end
end
