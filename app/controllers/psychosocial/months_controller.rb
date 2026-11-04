# RAAS do mês de um CAPS (ADR 0049; contrato §6, P13, P14, P24, P25, P37):
#   GET  /psychosocial/months/:month?health_unit_id
#        equipe lotada (coordenação e equipe): situação, fechamento, contadores e
#        os registros com problems (bloqueiam) e warnings (no_actions); sem
#        trilha (lista, sem texto clínico)
#   POST /psychosocial/months/:month/close  { health_unit_id }
#        coordenação lotada, com step-up → <mês>; 409 already_closed; 422
#        month_has_problems { problems: [ { error, path: "records.<id>" } ] }
#   POST /psychosocial/months/:month/reopen { health_unit_id, reason }
#        coordenação lotada, com step-up → <mês>; 409 already_exported | month_open
# `month` é "YYYY-MM" (senão 422 invalid_request `month`); fechar mês futuro
# também é recusado assim. Ids na URL; o motivo só no corpo.
module Psychosocial
  class MonthsController < BaseController
    MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/
    CLOSE_KEYS = %w[health_unit_id].freeze
    REOPEN_KEYS = %w[health_unit_id reason].freeze

    before_action :require_lead!, only: %i[close reopen]
    before_action :require_step_up!, only: %i[close reopen]

    def show
      return forbid unless Access.staff?(Current.user)
      return unless query_only!("health_unit_id")

      unit = staff_unit!(request.query_parameters["health_unit_id"])
      return unless unit

      month = parse_month
      return render_refusal("month") unless month

      render json: month_json(unit, month)
    end

    def close
      unit, month = write_target(CLOSE_KEYS)
      return unless unit
      return render_refusal("month") if month > Time.zone.today.beginning_of_month

      result = CloseMonth.call(unit: unit, month: month, by: Current.user)
      return render_failure(result) if result.failure?

      render json: month_json(unit, month)
    end

    def reopen
      unit, month = write_target(REOPEN_KEYS)
      return unless unit

      result = ReopenMonth.call(unit: unit, month: month, reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: month_json(unit, month)
    end

    private

    # Escrita: nada na query, só as chaves conhecidas no corpo, o CAPS lotado e
    # o mês da URL. -> [unit, month] | nil (já renderizou a recusa).
    def write_target(keys)
      return unless query_only!

      unknown = (body.keys - keys).first
      if unknown
        render_refusal(unknown.to_s[0, KEY_PATH_MAX])
        return
      end

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      month = parse_month
      unless month
        render_refusal("month")
        return
      end

      [ unit, month ]
    end

    # -> Date (dia 1º) | nil
    def parse_month
      match = params[:month].to_s.match(MONTH)
      match && Date.new(match[1].to_i, match[2].to_i, 1)
    end

    def month_json(unit, month)
      closure = PsychosocialMonthClosure.active.includes(closed_by_user: :professional).find_by(health_unit_id: unit.id, month: month)
      status = if MonthlyRecords.exported?(unit.id, month) then "exported"
               elsif closure then "closed"
               else "open"
               end
      Json.month(unit: unit, month: month, status: status, closure: closure, report: MonthProblems.for(health_unit: unit, month: month),
                 cbos: closure ? Access.cbos([ closure.closed_by_user_id ], unit.id) : {})
    end
  end
end
