# Alerta a secretaria municipal sobre triagem urgente. Ver ADR-0007 e ADR-0008.
# Fila urgent, SLA em segundos.
class AlertMunicipalityJob < ApplicationJob
  include IdempotentConsumer
  queue_as :urgent

  def consume(event)
    triagem = Triagem.find(event.aggregate_id)
    municipality_id = triagem.conversation.municipality_id
    return unless municipality_id

    # HTTP/E-mail para a secretaria fica em job próprio (ADR-0014).
    # Aqui só registramos a intenção e enfileiramos o envio.
    DispatchMunicipalityAlertJob.perform_later(
      municipality_id: municipality_id,
      triagem_id: triagem.id,
      tier: triagem.tier,
      priority: triagem.priority,
      occurred_at: event.occurred_at.iso8601
    )
  end
end
