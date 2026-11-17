# /vector_control/reports/:name (módulo 35a, ADR 0054; contrato §10, §12;
# Q8): os sete relatórios (Catalog::REPORTS) em JSON (VectorReport), em CSV
# (`.csv`, VectorControl::Csv) e, só o `liraa`, em PDF (`.pdf`,
# Liraa::Pdf). Nome desconhecido, outra extensão ou `.pdf` de outro → 404.
# Leem a coordenação e o municipal_admin (todos) e o vector_lab (só
# Reports::LAB_REPORTS); os outros → 403 missing_role. A query só com as
# chaves do relatório (Reports::FILTERS); filtro inválido → 422
# invalid_request com path. CSV e PDF com Content-Disposition attachment, sem
# cache e sem pessoa no nome do arquivo. Só contagens: sem trilha.
module VectorControl
  class ReportsController < BaseController
    FORMATS = %w[json csv pdf].freeze

    def show
      name = params[:name]
      return not_found unless Catalog::REPORTS.include?(name)
      return forbid unless readable?(name)

      format = params[:format]
      return not_found unless format.nil? || FORMATS.include?(format)
      return not_found if format == "pdf" && name != "liraa"
      return unless query_only!(*Reports::FILTERS.fetch(name))

      result = Reports.build(name, filters: request.query_parameters)
      return render_failure(result) if result.failure?

      report = result.payload.fetch(:report)
      case format
      when "csv" then download Csv.build(report), type: "text/csv; charset=utf-8", filename: filename(name, "csv")
      when "pdf"
        download Liraa::Pdf.build(result.payload.fetch(:survey), report: report), type: "application/pdf",
                                                                                 filename: filename(name, "pdf")
      else render json: report
      end
    end

    private

    def readable?(name)
      user = Current.user
      return true if Access.coordinator?(user) || user&.has_role?("municipal_admin")

      Access.lab?(user) && Reports::LAB_REPORTS.include?(name)
    end

    def filename(name, extension) = "#{name}-#{Time.zone.today.iso8601}.#{extension}"

    def download(data, type:, filename:)
      response.headers["Cache-Control"] = "no-store"
      send_data data, type: type, disposition: "attachment", filename: filename
    end
  end
end
