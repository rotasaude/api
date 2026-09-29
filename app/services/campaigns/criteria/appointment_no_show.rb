# Falta (no_show, só a partir de confirmed — MarkNoShowAppointmentsJob) com o
# horário marcado no período.
module Campaigns
  module Criteria
    class AppointmentNoShow
      def self.relation(params)
        Appointment.where(status: "no_show", scheduled_at: Criteria.period(params)).select(:citizen_id)
      end
    end
  end
end
