# Zera o campo raw das InboundMessage antigas, preservando metadados para
# auditoria mas removendo PII. Ver ADR-0014 (retenção) e nota operacional.
class PurgeInboundRawJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  # Janela de retenção do raw (ADR-0014). config/recurring.yml agenda com este
  # mesmo valor (spec/jobs/purge_inbound_raw_job_spec.rb garante a igualdade).
  RAW_RETENTION_DAYS = 90

  def perform(older_than_days: RAW_RETENTION_DAYS)
    cutoff = older_than_days.days.ago
    count = InboundMessage.where("created_at < ?", cutoff)
                          .where.not(raw: nil)
                          .update_all(raw: nil)
    Rails.logger.info("[purge_inbound_raw] cleared=#{count} cutoff=#{cutoff.iso8601}")
  end
end
