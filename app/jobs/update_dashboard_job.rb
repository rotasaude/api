# Atualiza dashboard_metrics incremental por triagem.completed. Ver ADR-0007.
# Reconstrução completa em scripts/rebuild_dashboard_metrics.rb (recurring).
class UpdateDashboardJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def consume(event)
    triagem = Triagem.find(event.aggregate_id)
    municipality_id = triagem.conversation.municipality_id
    date = (triagem.completed_at || Time.current).to_date.iso8601

    DashboardMetric.bump!(
      municipality_id: municipality_id,
      dimension: "triagens_by_tier",
      period: date,
      key: triagem.tier.to_s
    )

    DashboardMetric.bump!(
      municipality_id: municipality_id,
      dimension: "triagens_total",
      period: date,
      key: "total"
    )
  end
end
