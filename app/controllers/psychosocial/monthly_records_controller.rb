# Situação de rua da RAAS do mês (ADR 0049; contrato §6, P6):
#   PATCH /psychosocial/monthly_records/:id { homeless: Boolean }
#        equipe lotada no CAPS do registro → { id, enrollment_id, health_unit_id,
#        month, status, homeless }; fora de `open` → 409 record_not_open
# Registro de CAPS onde quem pede não está lotado → 404. Sem trilha (nada
# clínico na resposta).
module Psychosocial
  class MonthlyRecordsController < BaseController
    def update
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      record = uuid?(params[:id]) ? PsychosocialMonthlyRecord.find_by(id: params[:id].downcase) : nil
      return not_found unless record && Access.can_read?(Current.user, record)

      result = UpdateMonthlyRecord.call(record: record, attrs: body)
      return render_failure(result) if result.failure?

      render json: Json.monthly_record(result.payload.fetch(:record))
    end
  end
end
