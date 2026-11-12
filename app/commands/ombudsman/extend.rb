# POST /ombudsman/manifestations/:id/extend (ADR 0051; contrato §2, §9; §16
# Q8, Q17, Q32). O ouvidor prorroga o prazo do ciclo uma vez (o marcador
# `extended`; o prazo soma extension_days da configuração VIGENTE, Q17), de
# `in_analysis`, `forwarded` ou `awaiting_complement` — o estado não muda:
# - já prorrogada no ciclo → 422 already_extended;
# - `text` (a justificativa) em TEXT (10..4000, sem as bordas), cifrado em
#   `extension_reason`; vai ao cidadão como resposta intermediária: evento
#   `extended` visível com o texto e aviso `interim_response`
#   (Ombudsman::Notify, a ÚLTIMA escrita — F-24).
# Sob Ombudsman::Lock, com `expected_state` (409 manifestation_changed).
module Ombudsman
  module Extend
    FROM = %w[in_analysis forwarded awaiting_complement].freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "text", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition) | fail(:already_extended)
    def call(manifestation_id:, expected_state:, text:, by:, now: Time.current)
      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)
        next Result.fail(:already_extended) if manifestation.extended

        manifestation.update!(extended: true, extension_reason: value, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "extended", actor: "staff", actor_user: by,
                               text: value, data: {}, visible_to_citizen: true, created_at: now)
        Notify.call(manifestation: manifestation, kind: "interim_response", now: now)
        Result.ok(manifestation: manifestation)
      end
    end
  end
end
