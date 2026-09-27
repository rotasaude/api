# Purga domain_events além da janela de retenção (auditoria: 12 meses).
# Ver ADR-0005/0014. Roda uma vez por cidade ativa (EachCityJob): o delete_all
# atinge só o banco daquela cidade, pela conexão dela — sem RLS nem BYPASSRLS.
# O trigger domain_events_guard recusa DELETE dentro de 12 meses (F-07.1): uma
# janela menor é recusada aqui, antes de chegar ao banco.
class PurgeDomainEventsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  RETENTION_MONTHS = 12

  def perform(older_than_months: RETENTION_MONTHS)
    if older_than_months < RETENTION_MONTHS
      raise ArgumentError, "domain_events retention is at least #{RETENTION_MONTHS} months (got #{older_than_months})"
    end

    cutoff = older_than_months.months.ago
    count = DomainEvent.where("occurred_at < ?", cutoff).delete_all
    Rails.logger.info("[purge_domain_events] deleted=#{count} cutoff=#{cutoff.iso8601}")
  end
end
