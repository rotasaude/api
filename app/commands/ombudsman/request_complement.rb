# POST /ombudsman/manifestations/:id/request_complement (ADR 0051; contrato
# §2, §9; §16 Q8, Q32). A equipe pede ao manifestante um complemento, de
# `in_analysis`, e a manifestação fica `awaiting_complement` (prazo suspenso,
# cor `paused`):
# - uma vez por ciclo (`complement_used`) → senão 422 complement_already_used;
# - nunca na anônima (não há a quem pedir) → 422 complement_not_allowed;
# - `text` em TEXT (10..4000, sem as bordas), que vai ao cidadão.
# Grava `complement_requested_at = now` e `complement_used = true`; evento
# `complement_requested` visível ao cidadão com o texto; aviso
# `complement_requested` (Ombudsman::Notify, a ÚLTIMA escrita — F-24). Sob
# Ombudsman::Lock, com `expected_state` (409 manifestation_changed).
module Ombudsman
  module RequestComplement
    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "text", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    #  | fail(:complement_not_allowed) | fail(:complement_already_used)
    def call(manifestation_id:, expected_state:, text:, by:, now: Time.current)
      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless manifestation.state == "in_analysis"
        next Result.fail(:complement_not_allowed) if manifestation.anonymous?
        next Result.fail(:complement_already_used) if manifestation.complement_used

        manifestation.update!(state: "awaiting_complement", complement_requested_at: now, complement_used: true, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "complement_requested", actor: "staff", actor_user: by,
                               text: value, data: {}, visible_to_citizen: true, created_at: now)
        Notify.call(manifestation: manifestation, kind: "complement_requested", now: now)
        Result.ok(manifestation: manifestation)
      end
    end
  end
end
