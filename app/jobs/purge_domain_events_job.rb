# Purga domain_events além da janela de retenção (auditoria: 12 meses).
# Ver ADR-0005/0014. Roda uma vez por cidade ativa (EachCityJob): o delete_all
# atinge só o banco daquela cidade, pela conexão dela — sem RLS nem BYPASSRLS.
class PurgeDomainEventsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform(older_than_months: 12)
    cutoff = older_than_months.months.ago
    count = DomainEvent.where("occurred_at < ?", cutoff).delete_all
    Rails.logger.info("[purge_domain_events] deleted=#{count} cutoff=#{cutoff.iso8601}")
  end
end
