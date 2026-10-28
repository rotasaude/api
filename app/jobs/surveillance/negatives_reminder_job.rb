# Lembrete semanal da negativa (módulo 25, ADR 0043; contrato K7): às segundas,
# unidades notificadoras ativas que não registraram negativa da SEMANA
# ANTERIOR (epidemiológica, relativa ao dia na cidade) e não tiveram caso nela
# (Surveillance::WeekCases) entram em UM e-mail (MailJob kind "negatives", ref =
# a semana "YYYY-WW"). Ninguém pendente: nada. O MailJob relê as pendentes
# (WeekCases.pending_units) na hora de enviar.
module Surveillance
  class NegativesReminderJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      week = EpiWeek.current(Time.zone.today).pred
      return unless WeekCases.pending_units(week).exists?

      MailJob.perform_later(city_slug: Current.city.slug, kind: "negatives", ref: week.to_s)
    end
  end
end
