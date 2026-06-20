# Notifica o cidadão com o link do snapshot. Ver ADR-0007 e ADR-0014.
# Idempotência via concern; HTTP delegado para SendWhatsappJob.
class NotifyCitizenJob < ApplicationJob
  include IdempotentConsumer
  queue_as :default

  def handle(triagem_id:, **)
    triagem = Triagem.find(triagem_id)
    snapshot = triagem.report_snapshot or return   # GenerateReportJob ainda não rodou; vai tentar de novo via replay
    phone = triagem.conversation.phone

    SendWhatsappJob.perform_later(
      to: phone,
      body: "Sua triagem (#{triagem.tier}): #{snapshot.url}",
      municipality_id: triagem.municipality_id
    )
  end
end
