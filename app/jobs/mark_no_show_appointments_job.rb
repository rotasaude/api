# Horários confirmados cujo dia terminou (fuso da cidade) viram no_show; o pedido volta à fila (ADR 0019).
class MarkNoShowAppointmentsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    Appointment.where(status: "confirmed").where("scheduled_at < ?", Time.zone.today.beginning_of_day).find_each do |a|
      Appointments::Lapse.call(appointment: a, to: "no_show")
    end
  end
end
