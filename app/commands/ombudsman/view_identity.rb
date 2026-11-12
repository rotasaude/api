# POST /ombudsman/manifestations/:id/identity (ADR 0051; contrato §5, §8;
# §16 Q24/A26, U4). O ouvidor abre a identidade (o controlador já conferiu o
# papel): justificativa em JUSTIFICATION (10..500, sem as bordas), sem
# step-up — a justificativa e a trilha por abertura são o controle.
#
# Na transação, sob Ombudsman::Lock (cidadão, depois a manifestação — a ordem
# do Citizens::Erase: a leitura vê ou o cidadão, ou os manifestant_* que a
# exclusão copiou): sem ninguém a revelar (a anônima) → 422 no_identity e
# nada gravado; senão uma linha em ombudsman_identity_accesses (scope
# identity) e ombudsman.identity_viewed { manifestation_id, access_id }, uma
# por abertura. A identidade sai só no payload, nunca em erro, log ou evento.
module Ombudsman
  module ViewIdentity
    module_function

    # -> Result.ok(identity:) | fail(:invalid_request, details: { path: "justification", problems: })
    #  | fail(:not_found) | fail(:no_identity)
    def call(manifestation_id:, justification:, by:, now: Time.current)
      text = Input.text(justification, Catalog::JUSTIFICATION)
      unless text
        return Result.fail(:invalid_request, details: { path: "justification",
                                                        problems: [ { error: "invalid_request", path: "justification" } ] })
      end

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation
        next Result.fail(:no_identity) unless Json.identity_available?(manifestation)

        access = OmbudsmanIdentityAccess.create!(ombudsman_manifestation: manifestation, user: by, scope: "identity",
                                                 justification: text, created_at: now)
        DomainEvents.publish("ombudsman.identity_viewed", manifestation_id: manifestation.id, access_id: access.id)
        Result.ok(identity: Json.full_identity(manifestation))
      end
    end
  end
end
