# POST /ombudsman/inbox/:id/extend (ADR 0051; contrato §2, §6; §16 Q8, Q33,
# Q48). O respondente prorroga um encaminhamento `pending` uma vez: `due_on`
# + forwarding_extension_days (configuração vigente) e o motivo (`reason` em
# TEXT, 10..4000, sem as bordas) cifrado em `extension_reason`; a segunda →
# 422 already_extended. A manifestação não muda. Encaminhamento de outro
# destino → not_found. Evento `forwarding_extended` (da equipe: o respondente).
module Ombudsman
  module ExtendForwarding
    module_function

    # -> Result.ok(manifestation:, forwarding:) | fail(:invalid_request, details: { path: "reason", problems: })
    #  | fail(:not_found) | fail(:forwarding_changed) | fail(:invalid_transition) | fail(:already_extended)
    def call(forwarding_id:, expected_state:, reason:, by:, now: Time.current)
      text = Input.text(reason, Catalog::TEXT)
      return Input.refuse("reason") unless text

      Forwardings.as_responder(forwarding_id: forwarding_id, expected_state: expected_state, by: by) do |manifestation, forwarding|
        next Result.fail(:already_extended) if forwarding.extended

        forwarding.update!(extended: true, due_on: forwarding.due_on + OmbudsmanSetting.current.forwarding_extension_days,
                           extension_reason: text, updated_at: now)
        Forwardings.event!(manifestation, forwarding, "forwarding_extended", by: by, now: now)
        Result.ok(manifestation: manifestation, forwarding: forwarding)
      end
    end
  end
end
