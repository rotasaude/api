# Ficha espelho da RAAS do mês em PDF (ADR 0049; contrato §6, P14, P37;
# plano, Desvio 10):
#   GET /psychosocial/months/:month/sheets.pdf?health_unit_id=&enrollment_id=
# Coordenação lotada no CAPS ou faturista (qualquer CAPS ativo). Todas as
# fichas do mês, ou só a da matrícula (`enrollment_id` de outro CAPS ou
# inexistente → 404). Mês fechado: a foto. Mês aberto: marca "PRÉVIA" e dados
# ao vivo, só para a coordenação lotada; o faturista recebe 409 month_open
# (P43, minimização). Grava clinical_record.viewed por paciente (resource raas_sheet). Ids na
# URL; o PDF nunca passa pelo log; o nome do arquivo só tem CNES e mês.
module Psychosocial
  class SheetsController < BaseController
    def show
      return unless query_only!("health_unit_id", "enrollment_id")

      unit = raas_unit!(request.query_parameters["health_unit_id"])
      return unless unit

      month = month_from(params[:month])
      return render_refusal("month") unless month

      preview = !MonthlyRecords.closed?(unit.id, month)
      return render(json: { error: "month_open" }, status: :conflict) if preview && !lead_here?(unit)

      enrollment_id = request.query_parameters["enrollment_id"]
      if enrollment_id
        return not_found unless uuid?(enrollment_id) && PsychosocialEnrollment.exists?(id: enrollment_id, health_unit_id: unit.id)
      end

      entries = RaasRecords.for(unit: unit, month: month, enrollment_id: enrollment_id)
      pdf = MirrorSheetPdf.call(records: entries, preview: preview, unit: unit, month: month)
      entries.map { |entry| entry.record.psychosocial_enrollment.patient_id }.uniq.each do |patient_id|
        Trail.viewed!(patient: patient_id, user: Current.user, resource: "raas_sheet")
      end
      response.headers["Cache-Control"] = "no-store"
      send_data pdf, type: "application/pdf", disposition: "inline", filename: "RAAS-fichas-#{unit.cnes}-#{month.strftime('%Y%m')}.pdf"
    end

    private

    # A PRÉVIA ao vivo é da coordenação lotada no CAPS (P43); o faturista, mesmo
    # com outro papel, só lê a foto do mês fechado.
    def lead_here?(unit) = Access.lead?(Current.user) && Access.link(Current.user, unit.id).present?
  end
end
