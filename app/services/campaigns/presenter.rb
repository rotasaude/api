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
        created_at: campaign.created_at.iso8601, stats: stats(campaign), vaccinated_count: vaccinated_count(campaign)
      )
    end

    # Destinatários cujo paciente tem dose ATIVA de um dos imunobiológicos do
    # critério vaccine_overdue, aplicada depois de a linha do destinatário nascer
    # (V13). Nulo sem esse critério ou antes do envio (D12 do dashboard).
    def vaccinated_count(campaign)
      return nil unless campaign.status == "sent"

      criteria = Array(campaign.audience.dig("clinical", "all")).select { |c| c["kind"] == "vaccine_overdue" }
      return nil if criteria.empty?

      codes = criteria.flat_map { |c| c["immunobiological_codes"] }.map { |c| Vaccination::Immunobiologicals.normalize(c) }.uniq
      campaign.recipients.joins(:citizen).where.not(citizens: { patient_id: nil })
              .where(Immunization.active.where(immunobiological_code: codes)
                                 .where("immunizations.patient_id = citizens.patient_id")
                                 .where("immunizations.applied_at >= campaign_recipients.created_at").arel.exists)
              .count
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
