# POST /ombudsman/manifestations/:id/identity_consent (ADR 0051; contrato §5,
# §8; §16 Q32). O ouvidor registra que o manifestante autorizou (ou não) que
# a identidade fosse revelada: `granted` booleano e `text` em TEXT (10..4000,
# sem as bordas). Um evento `identity_consent_recorded` da equipe, com
# `data: { granted }`, o texto cifrado e nunca visível ao cidadão. Não revela
# nada: não grava acesso nem ombudsman.identity_viewed. Sem ninguém a
# consentir (a anônima) → 422 no_identity, como POST .../identity (A26).
module Ombudsman
  module RecordIdentityConsent
    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "granted" | "text", problems: })
    #  | fail(:not_found) | fail(:no_identity)
    def call(manifestation_id:, granted:, text:, by:, now: Time.current)
      return invalid("granted") unless [ true, false ].include?(granted)

      value = Input.text(text, Catalog::TEXT)
      return invalid("text") unless value

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation
        next Result.fail(:no_identity) unless Json.identity_available?(manifestation)

        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "identity_consent_recorded", actor: "staff", actor_user: by,
                               text: value, data: { "granted" => granted }, visible_to_citizen: false, created_at: now)
        Result.ok(manifestation: manifestation)
      end
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { error: "invalid_request", path: path } ] })
    private_class_method :invalid
  end
end
