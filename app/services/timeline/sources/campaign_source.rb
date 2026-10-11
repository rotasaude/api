# Campanhas (módulo 12): o convite (a linha do público congelado) e a
# participação, que é a leitura do aviso no wpda. O corpo da campanha não entra.
module Timeline
  module Sources
    module CampaignSource
      KIND = "campaign".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::CampaignRecipient.where(citizen_id: person.citizen_ids).includes(:campaign)
        Window.apply(scope, kind: KIND, column: "campaign_recipients.created_at", id_column: "campaign_recipients.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |recipient| entry(recipient) }
      end

      def entry(recipient)
        read_at = recipient.notice_read_at
        summary = read_at ? "Aviso lido em #{read_at.in_time_zone.strftime('%d/%m/%Y')}" : "Aviso não lido"
        status = read_at ? "read" : "unread"
        title = "Campanha — #{recipient.campaign.title}"
        Entry.new(kind: KIND, source_id: recipient.id, occurred_at: recipient.created_at, unit: nil, professional: nil,
                  title: title, summary: summary, status: status, detail_ref: { type: "campaign", id: recipient.campaign_id },
                  citizen: { title: title, summary: summary, status: status, professional_name: nil },
                  document: nil)
      end
    end
  end
end
