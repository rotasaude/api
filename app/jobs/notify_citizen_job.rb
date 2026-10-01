# Notifica o cidadão com o link do snapshot. Ver ADR-0010 e ADR-0005.
# Idempotência via concern; HTTP delegado para SendWhatsappJob.
class NotifyCitizenJob < ApplicationJob
  include IdempotentConsumer
  queue_as :default

  # F-04.7: GenerateReportJob (fila reports) e este job saem do mesmo
  # triage.completed, sem ordem garantida entre as filas. Snapshot ausente é
  # "ainda não", não "nunca": levantar faz a transação de with_city desfazer o
  # ProcessedEvent (e published_at fica nil), e o retry_on reenfileira o MESMO
  # event_id, que a dedup deixa passar. Esgotadas as tentativas, o job vai para
  # as falhas do Solid Queue — visível, nunca um link perdido em silêncio.
  class SnapshotNotReady < StandardError; end

  retry_on SnapshotNotReady, wait: 1.minute, attempts: 10

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)
    if triage.anonymized_at   # revogada/apagada antes da fila esvaziar (ADR 0026): nada a fazer
      Rails.logger.info("[NotifyCitizenJob] skip triagem anonimizada")
      return
    end
    # Na web o link aparece na própria tela final (spec 2026-09-22-web-citizen-
    # channel §3.2); não há para onde mandar mensagem.
    return if triage.conversation.channel_web?
    snapshot = triage.report_snapshot or raise SnapshotNotReady, "triage #{triage.id}: snapshot ainda não existe"
    phone = triage.conversation.phone

    SendWhatsappJob.perform_later(
      to: phone,
      message: Messaging::Reply.text("Sua triage (#{triage.tier}): #{snapshot.url}").to_h,
      city_slug: Current.city.slug
    )
  end
end
