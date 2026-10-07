# api#43 (ADR 0030; spec §6): o conteúdo de ficha recusada ou que desistiu é
# apagado 90 dias depois da última tentativa. Corrigir uma recusada regera a
# ficha da escuta (não reaproveita o conteúdo), então nada se perde. Diário,
# por cidade; o evento leva só a contagem (e só quando há algo apagado).
module Ledi
  class PurgeStalePayloadsJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    RETENTION_DAYS = 90

    def perform(older_than_days: RETENTION_DAYS)
      cutoff = older_than_days.days.ago
      count = LediOutboxEntry.where(status: %w[rejected failed]).where.not(payload: nil)
                             .where("COALESCE(last_attempted_at, created_at) < ?", cutoff)
                             .update_all(payload: nil, updated_at: Time.current)
      DomainEvents.publish("ledi.payload_purged", count: count) if count.positive?
    end
  end
end
