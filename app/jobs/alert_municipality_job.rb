# Alerta a secretaria municipal sobre triage urgente. Ver ADR-0010 e ADR-0006.
# Fila urgent, SLA em segundos.
class AlertMunicipalityJob < ApplicationJob
  include IdempotentConsumer
  queue_as :urgent

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)

    # HTTP/E-mail para a secretaria fica em job próprio (ADR-0005).
    # Aqui só registramos a intenção e enfileiramos o envio, para a MESMA cidade
    # do evento (Current.city, setado pelo with_city do IdempotentConsumer).
    #
    # occurred_at é o completed_at REAL da triage (CompleteTriage chama
    # triage.complete! antes de publicar triage.urgent, então já está setado
    # aqui), não Time.current: um redispatch (ResendPendingAlertsJob) pode
    # rodar horas depois do evento original, e o e-mail deve mostrar quando a
    # triage urgente de fato aconteceu, não quando o alerta foi (re)enviado.
    DispatchMunicipalityAlertJob.perform_later(
      city_slug: Current.city.slug,
      triage_id: triage.id,
      tier: triage.tier,
      priority: triage.priority,
      occurred_at: triage.completed_at.iso8601
    )
  end
end
