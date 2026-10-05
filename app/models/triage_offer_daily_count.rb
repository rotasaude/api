# Quantas vezes cada protocolo foi mostrado em oferta num dia (desvio 1 do
# plano do módulo 15). Agregado, sem coluna de pessoa.
class TriageOfferDailyCount < ApplicationRecord
  def self.increment!(names, day:)
    rows = names.uniq.map { |name| { day: day, protocol_name: name, offered: 1 } }
    return if rows.empty?

    upsert_all(rows, unique_by: :idx_triage_offer_daily_counts_cell, record_timestamps: false,
                     on_duplicate: Arel.sql("offered = triage_offer_daily_counts.offered + 1"))
  end
end
