# Zera o campo raw das InboundMessage antigas, preservando metadados para
# auditoria mas removendo PII. Ver ADR-0011 (retenção) e nota operacional.
class PurgeInboundRawJob < ApplicationJob
  include AdminRoleJob
  queue_as :housekeeping

  def perform(older_than_days: 90)
    cutoff = older_than_days.days.ago
    count = InboundMessage.where("created_at < ?", cutoff)
                          .where.not(raw: nil)
                          .update_all(raw: nil)
    Rails.logger.info("[purge_inbound_raw] cleared=#{count} cutoff=#{cutoff.iso8601}")
  end
end
