# Horários sem confirmação no prazo viram expired; o pedido volta à fila (ADR 0019).
class ExpireUnconfirmedAppointmentsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    Appointment.where(status: "scheduled").where("confirmation_deadline_at <= ?", Time.current).find_each do |a|
      Appointments::Lapse.call(appointment: a, to: "expired")
    end
  end
end
