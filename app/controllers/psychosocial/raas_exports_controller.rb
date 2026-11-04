# Remessa RAAS do mês (ADR 0049; contrato §6, P4, P15, P43; plano, Desvios 8
# e 9). Coordenação lotada no CAPS ou faturista (sem lotação):
#   GET  /psychosocial/raas_exports?health_unit_id&month
#        as remessas do CAPS, ativo ou desativado (a desativação não torna o
#        arquivo inacessível), do mês com `month`: { items: [ { id,
#        health_unit_id, month, competence, layout_version, records_count,
#        sha256, created_at, created_by: <pro> } ] } — sem nome nem dado
#        clínico, sem trilha (P4: o faturista acha a remessa sem ler a RAAS
#        nominal)
#   POST /psychosocial/raas_exports { health_unit_id, month }, com step-up,
#        só para CAPS ativo → 201 a remessa; 422 raas_layout_unavailable
#        (layout oficial é gate) | nothing_to_export (nenhum registro com ação
#        RAAS no mês; nada gravado); 409 month_open | already_exported
#   GET  /psychosocial/raas_exports/:id/file
#        o arquivo, também de CAPS desativado (application/octet-stream,
#        RAAS-<cnes>-<competência>.txt); evento psychosocial.raas_downloaded
#        (raas_export_id) e clinical_record.viewed por paciente (resource
#        raas_file); conteúdo que não bate com o sha256 gravado não sai (409
#        integrity_mismatch).
# Ids na URL; o conteúdo do arquivo nunca passa pelo log.
module Psychosocial
  class RaasExportsController < BaseController
    CREATE_KEYS = %w[health_unit_id month].freeze

    before_action :raas_role!
    before_action :require_step_up!, only: :create

    def index
      return unless query_only!("health_unit_id", "month")

      unit = raas_unit!(request.query_parameters["health_unit_id"], active_only: false)
      return unless unit

      scope = PsychosocialRaasExport.where(health_unit_id: unit.id)
      if request.query_parameters.key?("month")
        month = month_from(request.query_parameters["month"])
        return render_refusal("month") unless month

        scope = scope.where(month: month)
      end
      exports = scope.includes(created_by_user: :professional).order(month: :desc, created_at: :desc).to_a
      cbos = Access.cbos(exports.map(&:created_by_user_id), unit.id)
      render json: { items: exports.map { |export| Json.raas_export(export, cbos) } }
    end

    def create
      return unless query_only!

      unknown = (body.keys - CREATE_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      unit = raas_unit!(body_param("health_unit_id"))
      return unless unit

      month = month_from(body_param("month"))
      return render_refusal("month") unless month

      result = ExportRaas.call(unit: unit, month: month, by: Current.user)
      return render_failure(result) if result.failure?

      export = result.payload.fetch(:export)
      render json: Json.raas_export(export, Access.cbos([ export.created_by_user_id ], unit.id)), status: :created
    end

    def file
      return unless query_only!

      export = uuid?(params[:id]) ? PsychosocialRaasExport.includes(:health_unit).find_by(id: params[:id]) : nil
      return not_found unless export && raas_reader?(export.health_unit_id)

      bytes = Base64.strict_decode64(export.file_data)
      # Decifrado ≠ sha256 gravado → nada sai (nem conteúdo, nem trilha de download).
      return render(json: { error: "integrity_mismatch" }, status: :conflict) unless Digest::SHA256.hexdigest(bytes) == export.sha256

      DomainEvents.publish("psychosocial.raas_downloaded", raas_export_id: export.id)
      patient_ids(export).each { |patient_id| Trail.viewed!(patient: patient_id, user: Current.user, resource: "raas_file") }
      response.headers["Cache-Control"] = "no-store"
      send_data bytes, type: "application/octet-stream", disposition: "attachment",
                       filename: "RAAS-#{export.health_unit.cnes}-#{export.competence}.txt"
    end

    private

    def patient_ids(export)
      PsychosocialMonthlyRecord.where(psychosocial_raas_export_id: export.id).joins(:psychosocial_enrollment)
                               .distinct.pluck("psychosocial_enrollments.patient_id")
    end
  end
end
