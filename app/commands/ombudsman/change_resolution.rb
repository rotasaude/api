# POST /ombudsman/manifestations/:id/change_resolution (ADR 0051; contrato §2;
# §16 Q8, Q32). O ouvidor muda a resolutividade de uma manifestação
# `answered` (o estado não muda):
# - `resolution` em RESOLUTIONS e só nos tipos que a têm (RESOLUTION_KINDS) →
#   senão 422 `path: "resolution"`;
# - `text` (a justificativa) em TEXT (10..4000, sem as bordas).
# Evento interno `resolution_changed` (nunca visível ao cidadão) com o texto
# e `data: { changes: { resolution: [antes, depois] } }`. Sem aviso nem evento
# de domínio. Sob Ombudsman::Lock, com `expected_state` (409
# manifestation_changed).
module Ombudsman
  module ChangeResolution
    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "resolution" | "text", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation_id:, expected_state:, resolution:, text:, by:, now: Time.current)
      return Input.refuse("resolution") unless Catalog::RESOLUTIONS.include?(resolution)

      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless manifestation.state == "answered"
        next Input.refuse("resolution") unless Catalog::RESOLUTION_KINDS.include?(manifestation.kind)

        before = manifestation.resolution
        manifestation.update!(resolution: resolution, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "resolution_changed", actor: "staff", actor_user: by,
                               text: value, data: { "changes" => { "resolution" => [ before, resolution ] } },
                               visible_to_citizen: false, created_at: now)
        Result.ok(manifestation: manifestation)
      end
    end
  end
end
