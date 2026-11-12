# POST /ombudsman/manifestations/:id/interim_response (ADR 0051; contrato §2,
# §9; §16 Q8, Q32). A equipe manda ao cidadão uma resposta intermediária, em
# qualquer estado aberto; não mexe no estado nem no prazo:
# - nunca na anônima (não há a quem responder) → 422 not_allowed_anonymous;
# - `text` em TEXT (10..4000, sem as bordas).
# Evento `interim_response` visível com o texto e aviso `interim_response`
# (Ombudsman::Notify, a ÚLTIMA escrita — F-24). Sob Ombudsman::Lock, com
# `expected_state` (409 manifestation_changed).
module Ombudsman
  module InterimResponse
    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "text", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition) | fail(:not_allowed_anonymous)
    def call(manifestation_id:, expected_state:, text:, by:, now: Time.current)
      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless manifestation.open?
        next Result.fail(:not_allowed_anonymous) if manifestation.anonymous?

        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "interim_response", actor: "staff", actor_user: by,
                               text: value, data: {}, visible_to_citizen: true, created_at: now)
        Notify.call(manifestation: manifestation, kind: "interim_response", now: now)
        Result.ok(manifestation: manifestation)
      end
    end
  end
end
