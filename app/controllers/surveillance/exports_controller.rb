# Saídas da vigilância (contrato §7; papel `surveillance`; K10):
#   GET /surveillance/notifications/:id/form.pdf   a ficha no formato do Sinan (trilha por pessoa)
#   GET /surveillance/exports/week.csv?week=AAAA-SS  uma linha por notificação da semana (trilha de lista)
# Download sem dado pessoal no nome do arquivo e sem cache. `week` é a única
# chave de query aceita (e só no CSV).
module Surveillance
  class ExportsController < BaseController
    before_action { forbid unless surveillance? }

    def form
      return unless query_only!

      notification = uuid?(params[:id]) ? DiseaseNotification.find_by(id: params[:id]) : nil
      return not_found unless notification

      bytes = Pdf.call(notification)
      Trail.person_viewed!(user: Current.user, patient_id: notification.patient_id)
      download bytes, type: "application/pdf", filename: "notificacao-#{notification.id}.pdf"
    end

    def week
      return unless query_only!(:week)

      epi_week = EpiWeek.parse(params[:week])
      return render_error("invalid_week") if epi_week.nil?

      built = Csv.build(week: epi_week)
      Trail.listed!(user: Current.user, notification_ids: built.fetch(:ids)) if built.fetch(:ids).any?
      download built.fetch(:csv), type: "text/csv; charset=utf-8", filename: "notificacoes-#{epi_week}.csv"
    end

    private

    def download(data, type:, filename:)
      response.headers["Cache-Control"] = "no-store"
      send_data data, type: type, disposition: "attachment", filename: filename
    end
  end
end
