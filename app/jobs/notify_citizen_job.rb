# Notifica o cidadão com o link do snapshot. Ver ADR-0010 e ADR-0005.
# Idempotência via concern; HTTP delegado para SendWhatsappJob.
class NotifyCitizenJob < ApplicationJob
  include IdempotentConsumer
  queue_as :default

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)
    # Na web o link aparece na própria tela final (spec 2026-09-22-web-citizen-
    # channel §3.2); não há para onde mandar mensagem.
    return if triage.conversation.channel_web?
    snapshot = triage.report_snapshot or return   # GenerateReportJob ainda não rodou; vai tentar de novo via replay
    phone = triage.conversation.phone

    SendWhatsappJob.perform_later(
      to: phone,
      message: Messaging::Reply.text("Sua triage (#{triage.tier}): #{snapshot.url}").to_h,
      city_slug: Current.city.slug
    )
  end
end
