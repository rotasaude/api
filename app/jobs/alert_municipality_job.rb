# Alerta a secretaria municipal sobre triage urgente. Ver ADR-0010 e ADR-0006.
# Fila urgent, SLA em segundos.
class AlertMunicipalityJob < ApplicationJob
  include IdempotentConsumer
  queue_as :urgent

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)

    # HTTP/E-mail para a secretaria fica em job próprio (ADR-0005).
    # Aqui só registramos a intenção e enfileiramos o envio.
    DispatchMunicipalityAlertJob.perform_later(
      municipality_id: triage.municipality_id,
      triage_id: triage.id,
      tier: triage.tier,
      priority: triage.priority,
      occurred_at: Time.current.iso8601
    )
  end
end
