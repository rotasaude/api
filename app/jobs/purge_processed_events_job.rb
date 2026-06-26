# Purga linhas antigas de processed_events. Ver ADR-0005.
# Janela default = 60d: maior que qualquer replay esperado, ver ADR-0009.
class PurgeProcessedEventsJob < ApplicationJob
  prepend AdminRoleJob
  queue_as :housekeeping

  def perform(older_than_days: 60)
    cutoff = older_than_days.days.ago
    count = ProcessedEvent.where("processed_at < ?", cutoff).delete_all
    Rails.logger.info("[purge_processed_events] deleted=#{count} cutoff=#{cutoff.iso8601}")
  end
end
