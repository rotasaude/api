# spec/services/scheduling/appointment_presenter_spec.rb
require "rails_helper"

RSpec.describe Scheduling::AppointmentPresenter do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:day) { Time.zone.today + 4 }
  let(:template) do
    ScheduleTemplate.create!(name: "Manhã", blocks: [ { "starts" => "08:00", "ends" => "09:00", "kind" => "bookable",
                                                       "appointment_type_key" => "consulta_medica" } ])
  end
  let(:shift) { shift!(link, starts_at: day.in_time_zone.change(hour: 8), template: template) }

  it "slot: forma única, sem justificativa; modelo editado marca outside_template; turno cancelado marca shift_cancelled" do
    appt = appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at)
    json = described_class.new(show_reason: true).call(appt)
    expect(json).to eq(
      id: appt.id, status: "confirmed", booking_kind: "slot", scheduled_at: appt.scheduled_at.iso8601,
      ends_at: appt.ends_at.iso8601, appointment_type_key: "consulta_medica", appointment_type_name: "Consulta médica",
      professional: { id: link.professional_id, name: link.professional.professional_name }, shift_id: shift.id,
      fit_in: false, outside_template: false, shift_cancelled: false,
      citizen: { id: citizen.id, cpf_masked: citizen.cpf_masked }
    )
    template.update!(blocks: [ { "starts" => "10:00", "ends" => "11:00", "kind" => "blocked" } ])
    shift.update!(cancelled_at: Time.current, cancelled_by_user: link.started_by_user, cancel_reason: "troca")
    json = described_class.new(show_reason: true).call(appt.reload)
    expect(json).to include(outside_template: true, shift_cancelled: true, scheduled_at: appt.scheduled_at.iso8601)
  end

  it "encaixe: justificativa só para quem marca; legacy com campos nulos" do
    fit = appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at, kind: "fit_in",
                                                                      reason: "retorno que não espera")
    expect(described_class.new(show_reason: true).call(fit)).to include(fit_in: true, fit_in_reason: "retorno que não espera",
                                                                         outside_template: false)
    expect(described_class.new(show_reason: false).call(fit)).not_to have_key(:fit_in_reason)

    other = triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit)
    legacy = Appointment.create!(request: other, citizen: other.citizen, health_unit: unit, scheduled_at: shift.starts_at,
                                 scheduled_by_user: link.started_by_user, status: "confirmed", confirmed_at: Time.current)
    expect(described_class.new(show_reason: true).call(legacy))
      .to include(booking_kind: "legacy", ends_at: nil, appointment_type_key: nil, appointment_type_name: nil,
                  professional: nil, shift_id: nil, fit_in: false, outside_template: false, shift_cancelled: false)
    expect(described_class.new(show_reason: true).call(legacy)).not_to have_key(:fit_in_reason)
  end

  it "slot cuja faixa do modelo virou de outro tipo: outside_template" do
    appt = appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at)
    template.update!(blocks: [ { "starts" => "08:00", "ends" => "09:00", "kind" => "bookable",
                                 "appointment_type_key" => "consulta_enfermagem" } ])
    expect(described_class.new(show_reason: false).call(appt.reload)).to include(outside_template: true)
  end
end
