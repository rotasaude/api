# POST /ombudsman/inbox/:id/decline (ADR 0051; contrato §2, §6; §16 Q8, Q9,
# Q33, Q48). O respondente recusa um encaminhamento `pending` (não é do
# destino): o motivo (`reason` em TEXT, 10..4000, sem as bordas) vai em
# `reply`, com `state = declined` (Q9); o último `pending` resolvido devolve a
# manifestação a `in_analysis`. Encaminhamento de outro destino → not_found.
# Evento `forwarding_declined` (da equipe: o respondente); sem evento de domínio.
module Ombudsman
  module DeclineForwarding
    module_function

    # -> Result.ok(manifestation:, forwarding:) | fail(:invalid_request, details: { path: "reason", problems: })
    #  | fail(:not_found) | fail(:forwarding_changed) | fail(:invalid_transition)
    def call(forwarding_id:, expected_state:, reason:, by:, now: Time.current)
      text = Input.text(reason, Catalog::TEXT)
      return Input.refuse("reason") unless text

      Forwardings.as_responder(forwarding_id: forwarding_id, expected_state: expected_state, by: by) do |manifestation, forwarding|
        forwarding.update!(state: "declined", reply: text, replied_by_user: by, replied_at: now, updated_at: now)
        Forwardings.settle!(manifestation, now: now)
        Forwardings.event!(manifestation, forwarding, "forwarding_declined", by: by, now: now)
        Result.ok(manifestation: manifestation, forwarding: forwarding)
      end
    end
  end
end
