# Saída para o sistema do estado (contrato §8, §13 G8; papel `care_regulator`):
#   GET /regulation/exports/state.csv?status=   o CSV livre (trilha de lista)
# `status` é a única chave de query (padrão `external`, dentro de
# QUEUE_STATUSES; outro valor → 422 invalid_request com path "status").
# Download sem cache e sem dado pessoal no nome do arquivo.
module CareRegulation
  class ExportsController < BaseController
    before_action { forbid unless regulator? }

    def state
      return unless query_only!(:status)

      status = request.query_parameters["status"].presence || StateCsv::DEFAULT_STATUS
      unless status.is_a?(String) && Catalog::QUEUE_STATUSES.include?(status)
        return render(json: { error: "invalid_request", path: "status" }, status: :unprocessable_entity)
      end

      built = StateCsv.build(status: status)
      Trail.listed!(user: Current.user, regulation_request_ids: built.fetch(:ids)) if built.fetch(:ids).any?
      response.headers["Cache-Control"] = "no-store"
      send_data built.fetch(:csv), type: "text/csv; charset=utf-8", disposition: "attachment",
                                   filename: "regulacao-estado-#{Time.zone.today.iso8601}.csv"
    end
  end
end
