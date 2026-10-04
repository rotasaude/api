# Atualiza dashboard_metrics incremental por triage.completed (ADR-0010).
# Reconstrução completa em RebuildDashboardMetricsJob (recurring).
class UpdateDashboardJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)  # já sob with_city: o banco é da cidade do evento
    if triage.anonymized_at   # revogada/apagada antes da fila esvaziar (ADR 0026): nada a fazer
      Rails.logger.info("[UpdateDashboardJob] skip triagem anonimizada")
      return
    end
    if Triage.revoked.exists?(id: triage.id) # revogada com atendimento (api#34): o recálculo do dia já a tirou
      Rails.logger.info("[UpdateDashboardJob] skip triagem revogada")
      return
    end
    date = (triage.completed_at || Time.current).to_date.iso8601

    DashboardMetric.bump!(
      dimension: "triages_by_tier",
      period: date,
      key: triage.tier.to_s
    )

    DashboardMetric.bump!(
      dimension: "triages_total",
      period: date,
      key: "total"
    )
  end
end
