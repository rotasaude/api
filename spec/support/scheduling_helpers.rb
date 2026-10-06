# spec/support/scheduling_helpers.rb
# Módulo 17 (ADR 0029): turnos, pedidos de triagem e horários gravados direto
# (cenário de teste). Os caminhos reais são ScheduleShift, Triages::Schedule e
# Appointments::Book/FitIn.
module SchedulingHelpers
  def type_row!(key, cbo: ["2251"], minutes: 20, origin: "city", active: true, name: key.humanize)
    AppointmentType.create!(key: key, name: name, duration_minutes: minutes, cbo_prefixes: cbo, origin: origin,
                            active: active)
  end

  # Médica(o) com vínculo ativo na unidade (o perfil nasce pelo link_professional! do módulo 10).
  def doctor_link!(unit, cbo: "225125", email: "medica-#{SecureRandom.hex(3)}@cidade.gov.br")
    link_professional!(staff_with(email, "health_professional"), unit, cbo: cbo)
  end

  def shift!(link, starts_at:, ends_at: starts_at + 4.hours, template: nil)
    ProfessionalShift.create!(professional_link: link, professional_id: link.professional_id, starts_at: starts_at,
                              ends_at: ends_at, created_by_user: link.started_by_user, schedule_template: template)
  end

  def triage_request!(citizen, unit:, type_key: "consulta_medica", priority: "routine", due_on: Time.zone.today + 30)
    triage = completed_web_triage_for(citizen)
    AppointmentRequest.create!(kind: "triage", origin_triage: triage, root_triage: triage, citizen: citizen,
                               target_unit: unit, appointment_type_key: type_key, priority: priority, due_on: due_on)
  end

  def appointment_row!(request, shift, starts_at:, minutes: 20, kind: "slot", status: "confirmed", reason: nil)
    Appointment.create!(
      request: request, citizen_id: request.citizen_id, health_unit_id: shift.professional_link.health_unit_id,
      scheduled_at: starts_at, ends_at: starts_at + minutes.minutes, scheduled_by_user: shift.created_by_user,
      status: status, confirmed_at: status == "confirmed" ? Time.current : nil,
      confirmation_deadline_at: status == "scheduled" ? starts_at - 1.day : nil,
      professional_id: shift.professional_id, shift_id: shift.id, appointment_type_key: "consulta_medica",
      booking_kind: kind, fit_in_reason: reason
    )
  end
end

RSpec.configure { |c| c.include SchedulingHelpers }
