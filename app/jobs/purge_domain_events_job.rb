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

    # O corte é a MESMA expressão do trigger (UTC, intervalo em SQL): um
    # `older_than_months.months.ago` em Ruby, no fuso de São Paulo, pode cair
    # um dia depois do corte do banco no fim de mês — o trigger recusaria uma
    # linha e o delete_all inteiro da cidade cairia.
    cutoff_sql = "(now() AT TIME ZONE 'UTC') - make_interval(months => ?)"
    cutoff = DomainEvent.connection.select_value(DomainEvent.sanitize_sql(["SELECT #{cutoff_sql}", older_than_months]))
    count = DomainEvent.where("occurred_at < #{cutoff_sql}", older_than_months).delete_all
    Rails.logger.info("[purge_domain_events] deleted=#{count} cutoff=#{cutoff}")
  end
end
