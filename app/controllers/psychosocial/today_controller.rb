# GET /psychosocial/today?health_unit_id&date= (ADR 0049; contrato §4): os
# grupos do dia e as matrículas com visita marcada na data (padrão hoje, no
# fuso da cidade). `date` fora da forma → 422 invalid_request `date`. Só
# <patient-ref> e <pro>, nada clínico; é uma lista, então não grava trilha.
module Psychosocial
  class TodayController < BaseController
    def show
      return unless query_only!("health_unit_id", "date")

      query = request.query_parameters
      unit = staff_unit!(query["health_unit_id"])
      return unless unit

      date = query.key?("date") ? Input.date(query["date"]) : Time.zone.today
      return render_refusal("date") unless date

      render json: Today.call(unit: unit, date: date)
    end
  end
end
