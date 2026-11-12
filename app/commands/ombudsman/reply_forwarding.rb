# POST /ombudsman/inbox/:id/reply (ADR 0051; contrato §2, §6; §16 Q8, Q33,
# Q48). O respondente do destino responde um encaminhamento `pending`
# (`body` em TEXT, 10..4000, sem as bordas; cifrado em `reply`); o último
# `pending` resolvido devolve a manifestação a `in_analysis`. Encaminhamento
# de outro destino → not_found. `expected_state` do encaminhamento (Q33).
# Evento `forwarding_replied` (da equipe: o respondente) e
# ombudsman.forwarding_replied { manifestation_id, forwarding_id }.
module Ombudsman
  module ReplyForwarding
    module_function

    # -> Result.ok(manifestation:, forwarding:) | fail(:invalid_request, details: { path: "body", problems: })
    #  | fail(:not_found) | fail(:forwarding_changed) | fail(:invalid_transition)
    def call(forwarding_id:, expected_state:, body:, by:, now: Time.current)
      text = Input.text(body, Catalog::TEXT)
      return Input.refuse("body") unless text

      Forwardings.as_responder(forwarding_id: forwarding_id, expected_state: expected_state, by: by) do |manifestation, forwarding|
        forwarding.update!(state: "replied", reply: text, replied_by_user: by, replied_at: now, updated_at: now)
        Forwardings.settle!(manifestation, now: now)
        Forwardings.event!(manifestation, forwarding, "forwarding_replied", by: by, now: now)
        DomainEvents.publish("ombudsman.forwarding_replied", manifestation_id: manifestation.id, forwarding_id: forwarding.id)
        Result.ok(manifestation: manifestation, forwarding: forwarding)
      end
    end
  end
end
