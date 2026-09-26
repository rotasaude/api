# Check-in de um horário (spec 2026-09-25 §2.10): confirmado, hoje no fuso
# da cidade e desta unidade.
module Attendances
  module AppointmentCheckInEligibility
    module_function

    def check(appointment, health_unit_id: nil)
      return :appointment_not_eligible unless appointment.status == "confirmed"
      return :not_today unless appointment.today?
      return :wrong_unit if health_unit_id.present? && appointment.health_unit_id != health_unit_id.to_s

      :ok
    end

    def eligible_for(citizens, health_unit_id)
      Appointment.where(citizen_id: citizens.select(:id), status: "confirmed", health_unit_id: health_unit_id)
                 .where(scheduled_at: Time.zone.today.all_day).order(:scheduled_at)
    end

    def failure_for(state, appointment)
      return Result.fail(state) unless state == :wrong_unit

      Result.fail(:wrong_unit, details: { unit_name: appointment.health_unit.name })
    end
  end
end
