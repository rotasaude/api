# JSON da campanha no dashboard (contrato do módulo 12). Nenhuma lista de
# destinatários, em nenhuma rota: só contagens (ADR 0024).
module Campaigns
  module Presenter
    module_function

    def summary(campaign)
      {
        id: campaign.id, title: campaign.title, status: campaign.status, send_at: campaign.send_at&.iso8601,
        dispatched_at: campaign.dispatched_at&.iso8601, recipients_count: campaign.recipients_count
      }
    end

    def full(campaign)
      summary(campaign).merge(
        body: campaign.body, audience: campaign.audience, failure_reason: campaign.failure_reason,
        sms_enabled: campaign.sms_enabled, phones_count: campaign.phones_count,
        created_at: campaign.created_at.iso8601, stats: stats(campaign)
      )
    end

    # Lidos e SMS contados ao vivo: encolhem quando a revogação apaga linhas.
    def stats(campaign)
      return nil unless campaign.status == "sent"

      counts = campaign.recipients.group(:sms_status).count
      {
        read_count: campaign.recipients.where.not(notice_read_at: nil).count,
        sms: CampaignRecipient::SMS_STATUSES.index_with { |status| counts.fetch(status, 0) }
      }
    end
  end
end
