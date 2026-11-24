# /zoonoses/reports/:name (módulo 35b, ADR 0054; contrato §8, §10, Q25): os seis
# relatórios (Catalog::REPORTS) em JSON e em CSV (`.csv`, VectorControl::Csv:
# BOM, `;`, `\r\n`). Nome desconhecido ou extensão fora de json/csv → 404. Leem
# `reader?` (a equipe, a coordenação e o municipal_admin); os outros → 403
# missing_role. A query só com as chaves do relatório (Reports::FILTERS); filtro
# inválido → 422 invalid_request com path. Só agregados: sem trilha, sem nome,
# CPF, CNS, telefone, endereço nem microchip. CSV sem cache.
module Zoonoses
  class ReportsController < BaseController
    FORMATS = %w[json csv].freeze

    before_action :reader!

    def show
      name = params[:name]
      return not_found unless Catalog::REPORTS.include?(name)

      format = params[:format]
      return not_found unless format.nil? || FORMATS.include?(format)
      return unless query_only!(*Reports::FILTERS.fetch(name))

      result = Reports.build(name, filters: request.query_parameters)
      return render_failure(result) if result.failure?

      report = result.payload.fetch(:report)
      if format == "csv"
        response.headers["Cache-Control"] = "no-store"
        send_data VectorControl::Csv.build(report), type: "text/csv; charset=utf-8", disposition: "attachment",
                                                    filename: "#{name}-#{Time.zone.today.iso8601}.csv"
      else
        render json: report
      end
    end
  end
end
