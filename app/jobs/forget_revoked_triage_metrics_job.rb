# Consumidor de consent.revoked (api#34): a triagem revogada sai das dimensões
# de triagem do dashboard_metrics também no caminho contínuo (F-05.13), para
# convergir com a reconstrução noturna (F-05.14), que já a exclui.
#
# Recalcula da fonte cada dia em que uma triagem da conversa foi concluída, em
# vez de decrementar: não depende do tier da triagem (o
# AnonymizeRevokedTriageJob o apaga, em qualquer ordem) e é idempotente.
# conversation_id só acha os dias; a métrica segue agregada por cidade.
class ForgetRevokedTriageMetricsJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(conversation_id:, **)
    Triage.status_completed.where(conversation_id: conversation_id).where.not(completed_at: nil)
          .pluck(:completed_at).map { |at| at.to_date.iso8601 }.uniq
          .each { |date| DashboardMetric.recompute_triage_day!(date) }
  end
end
