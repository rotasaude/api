# Notifica o cidadão com o link do snapshot. Ver ADR-0007 e ADR-0014.
# Idempotência via concern; HTTP delegado para SendWhatsappJob.
class NotifyCitizenJob < ApplicationJob
  include IdempotentConsumer
  queue_as :default

  def handle(triage_id:, **)
    triage = Triage.find(triage_id)
    snapshot = triage.report_snapshot or return   # GenerateReportJob ainda não rodou; vai tentar de novo via replay
    phone = triage.conversation.phone

    SendWhatsappJob.perform_later(
      to: phone,
      body: "Sua triage (#{triage.tier}): #{snapshot.url}",
      municipality_id: triage.municipality_id
    )
  end
end
