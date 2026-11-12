# A pesquisa de satisfação do cidadão (ADR 0051; contrato §10; §16 Q8, Q43;
# preflight F-26; a rota é da Task 15). Três respostas fechadas, sem texto
# livre: `met` (yes | partly | no), `clear` (boolean) e `score` (inteiro 1..5).
# - só em `answered` (senão 422 invalid_transition) e só com `citizen_id`
#   (identificada ou preservada — F-26);
# - até SATISFACTION_WINDOW_DAYS dias depois de `concluded_at`, na data local
#   (422 satisfaction_window_closed);
# - uma por manifestação: 409 already_answered; o índice único é a última
#   palavra (a corrida perdida cai no mesmo 409).
# Sob Ombudsman::Lock. Sem aviso, sem evento de domínio e sem log do valor.
module Ombudsman
  module RecordSatisfaction
    module_function

    # -> Result.ok(manifestation:, response:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:not_found) | fail(:invalid_transition) | fail(:already_answered) | fail(:satisfaction_window_closed)
    def call(manifestation:, met:, clear:, score:, now: Time.current)
      return Input.refuse("met") unless Catalog::MET.include?(met)
      return Input.refuse("clear") unless [ true, false ].include?(clear)
      return Input.refuse("score") unless score.is_a?(Integer) && Catalog::SCORE.cover?(score)

      ApplicationRecord.transaction(requires_new: true) do
        locked = Lock.manifestation!(manifestation.id)
        next Result.fail(:not_found) unless locked
        next Result.fail(:invalid_transition) unless locked.state == "answered" && locked.citizen_id.present?
        next Result.fail(:already_answered) if OmbudsmanSatisfactionResponse.exists?(ombudsman_manifestation_id: locked.id)
        unless Deadlines.within_window?(locked.concluded_at, Catalog::SATISFACTION_WINDOW_DAYS, today: now.in_time_zone.to_date)
          next Result.fail(:satisfaction_window_closed)
        end

        response = OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: locked, met: met, clear: clear, score: score,
                                                         created_at: now)
        Result.ok(manifestation: locked, response: response)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_answered)
    end
  end
end
