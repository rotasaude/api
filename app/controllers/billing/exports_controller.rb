# Versões do arquivo (contrato §5 com B9): a lista para faturista e admin;
# o arquivo só para o faturista, com trilha (billing_export.downloaded) e
# nome sem dado pessoal; conteúdo que não bate com o sha256 gravado não sai
# (409 integrity_mismatch). O conteúdo nunca passa pelo log.
module Billing
  class ExportsController < BaseController
    def index
      return forbid unless Access.reader?(Current.user)

      period = uuid?(params[:id]) ? BillingPeriod.find_by(id: params[:id]) : nil
      return not_found unless period

      exports = period.exports.includes(generated_by_user: :professional).order(version: :desc)
      render json: { exports: exports.map { |export| Json.export(export) } }
    end

    def file
      return forbid unless Access.clerk?(Current.user)

      export = uuid?(params[:id]) ? BillingExport.find_by(id: params[:id]) : nil
      return not_found unless export
      # M3: decifrado ≠ sha256 gravado → nada sai (nem conteúdo, nem trilha de download).
      return render_error(:integrity_mismatch, :conflict) unless Digest::SHA256.hexdigest(export.bytes) == export.sha256

      DomainEvents.publish("billing_export.downloaded", billing_export_id: export.id, user_id: Current.user.id)
      response.headers["Cache-Control"] = "no-store"
      send_data export.bytes, type: "text/plain; charset=us-ascii", disposition: "attachment",
                              filename: "bpa-#{export.cnes}-#{export.competence}-v#{export.version}.txt"
    end
  end
end
