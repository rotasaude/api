# Caixa de avisos (ADR 0024; F-12.4; ADR 0029 §6). A sessão é do TELEFONE: a
# caixa mostra os avisos de todos os cidadãos dele (D12), com cpf_masked quando
# há mais de um. Duas fontes: campanhas (campaign_recipients) e lembretes de
# horário (appointment_notices); mais novo primeiro entre as duas. unread_count
# ignora quem silenciou; os avisos continuam na lista. O id é opaco: a leitura
# procura nas duas fontes.
module CitizenApi
  class NoticesController < BaseController
    def index
      citizens = current_citizen_session.citizens.to_a
      ids = citizens.map(&:id)
      masked = citizens.size > 1 ? citizens.to_h { |c| [ c.id, c.cpf_masked ] } : {}
      counted = ids - CitizenContactPreference.where(citizen_id: ids, notices_muted: true).pluck(:citizen_id)
      campaigns = visible(ids).preload(:campaign).map { |row| [ row.campaign.dispatched_at, notice_json(row, masked[row.citizen_id]) ] }
      reminders = reminders(ids).map { |row| [ row.created_at, reminder_json(row, masked[row.citizen_id]) ] }
      render json: {
        # Mais novo primeiro; empate pelo id (decrescente), como era só com campanhas.
        notices: (campaigns + reminders).sort_by { |at, json| [ at, json[:id] ] }.reverse.map(&:last),
        unread_count: visible(counted).where(notice_read_at: nil).count +
                      AppointmentNotice.where(citizen_id: counted, read_at: nil).count
      }
    end

    # Idempotente e sem corrida: só grava quando ainda está NULL (os triggers
    # recusam trocar uma leitura já gravada).
    def read
      own = current_citizen_session.citizens.select(:id)
      if (row = visible(own).find_by(id: params[:id]))
        CampaignRecipient.where(id: row.id, notice_read_at: nil).update_all(notice_read_at: Time.current)
      elsif (notice = AppointmentNotice.where(citizen_id: own).find_by(id: params[:id]))
        AppointmentNotice.where(id: notice.id, read_at: nil).update_all(read_at: Time.current)
      else
        return render_error("not_found", :not_found)
      end
      render json: { ok: true }
    end

    private

    def visible(citizen_ids)
      CampaignRecipient.joins(:campaign).where(citizen_id: citizen_ids, campaigns: { status: "sent" })
    end

    def reminders(citizen_ids)
      AppointmentNotice.where(citizen_id: citizen_ids).includes(appointment: %i[health_unit professional])
    end

    def notice_json(row, cpf_masked)
      {
        kind: "campaign", id: row.id, title: row.campaign.title, body: row.campaign.body,
        dispatched_at: row.campaign.dispatched_at.iso8601, read: row.notice_read_at.present?, cpf_masked: cpf_masked
      }
    end

    # Horário legado (antes do módulo 17) não tem tipo nem profissional, como
    # em CitizenApi::AppointmentsController.
    def reminder_json(row, cpf_masked)
      appointment = row.appointment
      legacy = appointment.booking_kind == "legacy"
      {
        kind: "appointment_reminder", id: row.id, appointment_id: appointment.id,
        appointment_type_name: legacy ? nil : catalog.name_for(appointment.appointment_type_key),
        unit_name: appointment.health_unit.name, unit_address: Scheduling::UnitAddress.call(appointment.health_unit),
        scheduled_at: appointment.scheduled_at.iso8601,
        professional_name: legacy ? nil : appointment.professional&.professional_name,
        read: row.read_at.present?, cpf_masked: cpf_masked
      }
    end

    def catalog = @catalog ||= Scheduling::AppointmentTypes.catalog
  end
end
