# Alerta de triagem urgente à secretaria municipal. Ver ADR-0007.
class AlertMailer < ApplicationMailer
  def urgent(to:, triagem_id:, tier:, priority:, occurred_at:)
    @triagem_id = triagem_id
    @tier = tier
    @priority = priority
    @occurred_at = occurred_at
    mail(to: to, subject: "[rota-saúde] Triagem urgente — tier #{tier}")
  end
end
