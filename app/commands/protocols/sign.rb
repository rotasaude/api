# Um revisor assina uma versão para uma finalidade (spec de assinaturas §5).
#
# O mantenedor é recusado PELO TIPO DE ATOR, antes de qualquer outra coisa: ele
# responde "sim" a toda pergunta de papel (D6), então ProtocolPolicy#review?
# o deixaria passar. Assinar é aprovar, e aprovar é só de gente da cidade.
#
# Step-up de MFA é do chamador (endpoint da cidade), como em Publish.
#
# Result.ok(signature:) | Result.fail(:maintainer_cannot_sign|:forbidden|:invalid_purpose|
#   :not_found|:invalid_state|:contributor_cannot_sign|:already_signed)
module Protocols
  module Sign
    SIGNABLE_IN = { "publication" => "in_review", "activation" => "published" }.freeze

    def self.call(name:, version:, purpose:, by:)
      return Result.fail(:city_missing) if Current.city.nil?
      return Result.fail(:maintainer_cannot_sign, message: "o mantenedor não assina protocolo") unless by.actor_kind == "user"
      return Result.fail(:invalid_purpose) unless SIGNABLE_IN.key?(purpose.to_s)

      protocol = ProtocolDefinition.find_by(name: name, version: version)
      return Result.fail(:not_found) if protocol.nil?
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).review?

      expected = SIGNABLE_IN.fetch(purpose.to_s)
      # Fast fail on the un-locked read; re-checked under the lock below.
      # ProtocolPolicy#review? asks only the actor's role, never the record,
      # so it needs no re-check under the lock.
      unless protocol.status == expected
        return Result.fail(:invalid_state, message: "assinatura de #{purpose} só com a versão em #{expected} " \
                                                    "(está #{protocol.status})")
      end
      if protocol.contributions.exists?(actor_id: by.id, actor_kind: "user")
        return Result.fail(:contributor_cannot_sign, message: "quem editou a versão não a assina")
      end
      if Signatures.valid_signer_ids(protocol, purpose: purpose.to_s).include?(by.id)
        return Result.fail(:already_signed, message: "você já assinou este conteúdo para #{purpose}")
      end

      signature = nil
      failure = nil
      ApplicationRecord.transaction do
        # A concurrent Publish/Activate can move the version out of the
        # signable state between the read above and this insert — e.g. a
        # publication signature landing right after the version was already
        # published. Locking and re-checking the status here is what actually
        # closes that race; the insert only happens once the locked row still
        # matches the expected state.
        protocol.lock!

        unless protocol.status == expected
          failure = Result.fail(:invalid_state, message: "assinatura de #{purpose} só com a versão em #{expected} " \
                                                          "(está #{protocol.status})")
          raise ActiveRecord::Rollback
        end

        signature = ProtocolSignature.create!(protocol_definition: protocol, purpose: purpose.to_s, signer: by,
                                              content_digest: protocol.content_digest)
        DomainEvents.publish("protocol.signed",
                             protocol_definition_id: protocol.id, protocol_key: protocol.name,
                             version: protocol.version, purpose: purpose.to_s,
                             content_digest: signature.content_digest, actor: by.id, actor_kind: by.actor_kind)
      end

      return failure if failure

      Result.ok(signature: signature)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
