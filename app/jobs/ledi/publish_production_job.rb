# Publica na plataforma as contagens da fila LEDI da cidade (competência
# corrente e anterior, no fuso da cidade) para o console (desvio 7). Recorrente
# de cidade; idempotente (upsert). Retenção por idade (R26): a corrente e as 12
# anteriores.
module Ledi
  class PublishProductionJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    KEEP_MONTHS = 12

    def perform
      today = Time.zone.today
      city_id = Current.city.id
      now = Time.current
      rows = [ Ledi::Deadline.current(today), Ledi::Deadline.previous(today) ].map do |competence|
        { city_id: city_id, competence: competence, published_at: now }.merge(Ledi::ProductionSummary.counts(competence))
      end
      cutoff = (today << KEEP_MONTHS).strftime("%Y%m")
      PlatformRecord.transaction(requires_new: true) do
        CityProductionSummary.upsert_all(rows, unique_by: :idx_city_production_summaries_cell)
        CityProductionSummary.where(city_id: city_id).where("competence < ?", cutoff).delete_all
      end
    end
  end
end
