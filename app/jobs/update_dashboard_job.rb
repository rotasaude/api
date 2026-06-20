# Atualiza dashboard_metrics incremental por triagem.completed (ADR-0007 + 0020).
# Reconstrução completa em scripts/rebuild_dashboard_metrics.rb (recurring).
class UpdateDashboardJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(triagem_id:, **)
    triagem = Triagem.find(triagem_id)  # já sob with_tenant: vê só do município
    date = (triagem.completed_at || Time.current).to_date.iso8601

    DashboardMetric.bump!(
      municipality_id: triagem.municipality_id,
      dimension: "triagens_by_tier",
      period: date,
      key: triagem.tier.to_s
    )

    DashboardMetric.bump!(
      municipality_id: triagem.municipality_id,
      dimension: "triagens_total",
      period: date,
      key: "total"
    )
  end
end
