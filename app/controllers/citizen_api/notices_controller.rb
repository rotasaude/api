# Caixa de avisos (ADR 0024; F-12.4). A sessão é do TELEFONE: a caixa mostra
# os avisos de todos os cidadãos dele (D12), com cpf_masked quando há mais de
# um. unread_count ignora quem silenciou; os avisos continuam na lista.
module CitizenApi
  class NoticesController < BaseController
    def index
      citizens = current_citizen_session.citizens.to_a
      ids = citizens.map(&:id)
      masked = citizens.size > 1 ? citizens.to_h { |c| [ c.id, c.cpf_masked ] } : {}
      muted = CitizenContactPreference.where(citizen_id: ids, notices_muted: true).pluck(:citizen_id)
      rows = visible(ids).preload(:campaign).order("campaigns.dispatched_at DESC, campaign_recipients.id DESC")
      render json: {
        notices: rows.map { |row| notice_json(row, masked[row.citizen_id]) },
        unread_count: visible(ids - muted).where(notice_read_at: nil).count
      }
    end

    # Idempotente e sem corrida: só grava quando ainda está NULL (o trigger
    # recusa trocar uma leitura já gravada).
    def read
      row = visible(current_citizen_session.citizens.select(:id)).find_by(id: params[:id])
      return render_error("not_found", :not_found) unless row

      CampaignRecipient.where(id: row.id, notice_read_at: nil).update_all(notice_read_at: Time.current)
      render json: { ok: true }
    end

    private

    def visible(citizen_ids)
      CampaignRecipient.joins(:campaign).where(citizen_id: citizen_ids, campaigns: { status: "sent" })
    end

    def notice_json(row, cpf_masked)
      {
        id: row.id, title: row.campaign.title, body: row.campaign.body,
        dispatched_at: row.campaign.dispatched_at.iso8601, read: row.notice_read_at.present?, cpf_masked: cpf_masked
      }
    end
  end
end
