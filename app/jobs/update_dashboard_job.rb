# Atualiza dashboard_metrics incremental por triage.completed (ADR-0010).
# Reconstrução completa em RebuildDashboardMetricsJob (recurring).
class UpdateDashboardJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)  # já sob with_city: o banco é da cidade do evento
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
