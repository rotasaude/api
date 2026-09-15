# Alerta de triage urgente à secretaria municipal. Ver ADR-0010.
#
# Só os campos que já recebe (triage_id/tier/priority/occurred_at) — nenhum
# dado do cidadão (telefone, respostas, etc.) chega até aqui, então nenhum
# vaza no e-mail.
class AlertMailer < ApplicationMailer
  def urgent(to:, triage_id:, tier:, priority:, occurred_at:)
    @triage_id = triage_id
    @tier = tier
    @priority = priority
    # occurred_at chega como string ISO8601 (R42: só valores simples).
    # Normaliza para America/Sao_Paulo na exibição, independente do offset
    # que a string carregava.
    @occurred_at = Time.iso8601(occurred_at).in_time_zone("America/Sao_Paulo")
    mail(to: to, subject: "[rota-saúde] Triage urgente — tier #{tier}")
  end
end
