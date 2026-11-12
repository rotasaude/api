# POST /ombudsman/forwardings/:id/cancel (ADR 0051; contrato §2, §5; §16 Q8,
# Q32, Q33). A equipe cancela um encaminhamento `pending`; sem outro `pending`,
# a manifestação volta a `in_analysis`. `expected_state` é o do ENCAMINHAMENTO
# (Q33): outro → 409 forwarding_changed; igual fora de pending → 422
# invalid_transition. `reason` opcional, em TEXT (10..4000, sem as bordas),
# vai cifrado no evento `forwarding_cancelled` (nunca visível ao cidadão; o
# encaminhamento não tem coluna de motivo). Trava manifestação →
# encaminhamento (Lock.forwarding!).
module Ombudsman
  module CancelForwarding
    module_function

    # -> Result.ok(manifestation:, forwarding:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:not_found) | fail(:forwarding_changed) | fail(:invalid_transition)
    def call(forwarding_id:, expected_state:, reason:, by:, now: Time.current)
      text = nil
      unless reason.nil?
        text = Input.text(reason, Catalog::TEXT)
        return Input.refuse("reason") unless text
      end

      ApplicationRecord.transaction do
        locked = Lock.forwarding!(forwarding_id)
        next Result.fail(:not_found) unless locked

        manifestation, forwarding = locked
        refusal = Lock.check_forwarding(forwarding, expected_state)
        next refusal if refusal

        forwarding.update!(state: "cancelled", updated_at: now)
        Forwardings.settle!(manifestation, now: now)
        Forwardings.event!(manifestation, forwarding, "forwarding_cancelled", by: by, now: now, text: text)
        Result.ok(manifestation: manifestation, forwarding: forwarding)
      end
    end
  end
end
