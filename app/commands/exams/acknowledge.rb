# Ciência (spec §5 etapa 6; contrato §3, A10): o solicitante (motivo
# opcional); com o exame escalado, médico ou enfermeiro de equipe ativa da
# unidade do exame, com motivo. Recepção, outra unidade, fora da equipe e
# exame não escalado recusam. Repetir = 409 invalid_transition (Transition).
module Exams
  module Acknowledge
    MIN_REASON = 3

    module_function

    def call(order:, by:, reason: nil)
      reason = reason.is_a?(String) ? reason : nil
      ApplicationRecord.transaction do
        order.lock!
        if order.requester_user_id == by.id && by.has_role?("health_professional")
          by_team = false
        elsif order.escalated? && Access.team_member?(by, order.unit_id)
          by_team = true
          next Result.fail(:reason_required) if reason.to_s.strip.length < MIN_REASON && order.status == "resulted"
        else
          next Result.fail(order.escalated? ? :not_in_team : :not_requester)
        end
        Transition.call(order: order, kind: "acknowledged", actor_user: by, reason: reason, event_payload: { by_team: by_team })
      end
    end
  end
end
