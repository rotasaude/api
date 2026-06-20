# Notifica o cidadão com o link do snapshot. Ver ADR-0007 e ADR-0014.
# Idempotência via concern; HTTP delegado para SendWhatsappJob.
class NotifyCitizenJob < ApplicationJob
  include IdempotentConsumer
  queue_as :default

  def consume(event)
    triagem = Triagem.find(event.aggregate_id)
    snapshot = triagem.report_snapshot or return   # GenerateReportJob ainda não rodou; vai tentar de novo via replay
    phone = triagem.conversation.phone

    SendWhatsappJob.perform_later(
      to: phone,
      template: {
        name: "rota_saude_resultado",
        language: { code: "pt_BR" },
        components: [
          { type: "body", parameters: [
            { type: "text", text: triagem.tier.to_s },
            { type: "text", text: snapshot.url }
          ]}
        ]
      },
      context: { triagem_id: triagem.id, snapshot_id: snapshot.id }
    )
  end
end
