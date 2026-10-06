# Lembrete da véspera (ADR 0029 §6), cidade por cidade. Roda a cada 15
# minutos e só age das 17h às 20h no fuso da cidade (CityConnection.with usa o
# fuso dela); reminded_at faz a próxima rodada pular quem já recebeu.
module Appointments
  class RemindJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    FROM_HOUR = 17

    def perform
      now = Time.current
      return unless now.hour >= FROM_HOUR && Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.hour)

      tomorrow = (now.to_date + 1).in_time_zone.all_day
      Appointment.where(status: "confirmed", reminded_at: nil, scheduled_at: tomorrow).find_each do |appointment|
        Remind.call(appointment: appointment, now: now)
      end
    end
  end
end
