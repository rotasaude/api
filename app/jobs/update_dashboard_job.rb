# Atualiza dashboard_metrics incremental por triage.completed (ADR-0007 + 0020).
# Reconstrução completa em scripts/rebuild_dashboard_metrics.rb (recurring).
class UpdateDashboardJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)  # já sob with_tenant: vê só do município
    date = (triage.completed_at || Time.current).to_date.iso8601

    DashboardMetric.bump!(
      municipality_id: triage.municipality_id,
      dimension: "triages_by_tier",
      period: date,
      key: triage.tier.to_s
    )

    DashboardMetric.bump!(
      municipality_id: triage.municipality_id,
      dimension: "triages_total",
      period: date,
      key: "total"
    )
  end
end
