# Alerta de triage urgente à secretaria municipal. Ver ADR-0007.
class AlertMailer < ApplicationMailer
  def urgent(to:, triage_id:, tier:, priority:, occurred_at:)
    @triage_id = triage_id
    @tier = tier
    @priority = priority
    @occurred_at = occurred_at
    mail(to: to, subject: "[rota-saúde] Triage urgente — tier #{tier}")
  end
end
