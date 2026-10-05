# app/services/triages/counters.rb
# Contadores da aba "Catálogo de triagens" (spec 2026-10-05 §7; contratos §4.1;
# desvio 10 do plano): hoje e os 29 dias anteriores, no fuso da cidade.
# Agregados; cada valor de 1 a 4 vira nil (ADR 0025, Admin::SmallCount).
#   offered         — soma de triage_offer_daily_counts
#   started         — triagens criadas com o protocol_name (todos os canais)
#   completed       — Triage.counted_completed (exclui revogada)
#   from_suggestion — sugestões taken resolvidas na janela
module Triages
  module Counters
    WINDOW_DAYS = 30

    module_function

    def for(names, on: Time.zone.today)
      first_day = on - (WINDOW_DAYS - 1)
      since = first_day.in_time_zone.beginning_of_day
      offered = TriageOfferDailyCount.where(protocol_name: names, day: first_day..on).group(:protocol_name).sum(:offered)
      started = Triage.where(protocol_name: names, created_at: since..).group(:protocol_name).count
      completed = Triage.counted_completed.where(protocol_name: names, completed_at: since..).group(:protocol_name).count
      from_suggestion = TriageSuggestion.status_taken.where(protocol_name: names, resolved_at: since..)
                                        .group(:protocol_name).count
      names.to_h do |name|
        [ name, { offered: hide(offered[name]), started: hide(started[name]), completed: hide(completed[name]),
                  from_suggestion: hide(from_suggestion[name]) } ]
      end
    end

    def hide(value)
      count = value.to_i
      Admin::SmallCount.small?(count) ? nil : count
    end
  end
end
