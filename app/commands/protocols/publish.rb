# Publica uma versão de protocolo: move `in_review` → `published`.
# Ver ADR-0009 (lifecycle de dois eixos: publish ≠ activate) e a spec de
# assinaturas §4 (duas assinaturas de publicação válidas, sempre).
#
# Pré-requisitos:
# - Conexão da cidade aberta e Current.city setado (CityResolution do request).
# - Step-up MFA conferido pelo chamador (ADR-0011) — este command não sabe de MFA.
#
# `by:` é um User (com protocol_publisher) ou Maintenance::MaintainerActor — o
# mantenedor publica quando as assinaturas da cidade já existem, nunca antes
# (D6: ele responde "sim" a ProtocolPolicy, mas não assina).
#
# Comportamento:
# - Encontra ProtocolDefinition por version (e name, se informado), no banco da cidade.
# - Autoriza via ProtocolPolicy (protocol_publisher).
# - Só publica a partir de `in_review` (draft não é mais publicável — spec §4).
# - Roda o portão completo (Protocols::Gate) e exige Signatures.missing(...,
#   purpose: "publication") == 0.
# - Move a versão alvo para `published` (NÃO `active` — vigência é ato à parte,
#   ver Protocols::Activate). `published` ≠ `active`.
# - Audita via DomainEvents.publish("protocol.published", ...), com actor_kind
#   e, quando informado, correlation_id.
#
# Concorrência: a leitura antes do lock pode estar obsoleta quando este command
# escreve. Trava a linha (`lock!`) dentro da transação e reconfere status, o
# portão e as assinaturas no registro travado — só então decide e escreve.
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|
#   :invalid_state|:invalid|:signatures_missing)
module Protocols
  module Publish
    # Spec de assinaturas §4: publicar só a partir de in_review (draft não é
    # mais publicável).
    PUBLISHABLE_FROM = %w[in_review].freeze

    def self.call(version:, by:, name: nil, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?

      conditions = { version: version }
      conditions[:name] = name if name
      candidates = ProtocolDefinition.where(conditions)
      return Result.fail(:not_found) if candidates.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if candidates.count > 1

      protocol = candidates.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).publish?

      # Fast fail on the un-locked read (avoids opening a transaction and
      # querying signatures for the common case); re-checked under the lock
      # below, which is what actually guards the race. ProtocolPolicy#publish?
      # asks only the actor's role, never the record, so it needs no re-check
      # under the lock.
      unless PUBLISHABLE_FROM.include?(protocol.status)
        return Result.fail(:invalid_state, message: "só in_review pode ser publicado (está #{protocol.status})")
      end

      gate = Protocols::Gate.call(protocol.definition)
      return Result.fail(:invalid, message: gate.errors.join("; ")) unless gate.valid?

      if Signatures.missing(protocol, purpose: "publication").positive?
        return Result.fail(:signatures_missing, message: Signatures.shortfall_message(protocol, purpose: "publication"))
      end

      failure = nil
      ApplicationRecord.transaction do
        # A concurrent SaveDraft can send this same version back to draft
        # (Task 4: editing an in-review version does that) between the reads
        # above and this write — the pre-lock signature check would still see
        # the OLD digest's signatures as valid on the stale in-memory record.
        # Locking and re-reading here is what closes that: status, the gate
        # and Signatures are all re-run against the locked row's actual
        # current content, and so is the event's content_digest below, never
        # the pre-lock read.
        protocol.lock!

        unless PUBLISHABLE_FROM.include?(protocol.status)
          failure = Result.fail(:invalid_state, message: "só in_review pode ser publicado (está #{protocol.status})")
          raise ActiveRecord::Rollback
        end

        locked_gate = Protocols::Gate.call(protocol.definition)
        unless locked_gate.valid?
          failure = Result.fail(:invalid, message: locked_gate.errors.join("; "))
          raise ActiveRecord::Rollback
        end

        if Signatures.missing(protocol, purpose: "publication").positive?
          failure = Result.fail(:signatures_missing,
                                message: Signatures.shortfall_message(protocol, purpose: "publication"))
          raise ActiveRecord::Rollback
        end

        signers = Signatures.valid_signer_ids(protocol, purpose: "publication")

        protocol.update!(status: "published")

        DomainEvents.publish("protocol.published", **{
          protocol_definition_id: protocol.id, protocol_key: protocol.name, version: protocol.version,
          content_digest: protocol.content_digest, signers: signers,
          actor: by.id, actor_kind: by.actor_kind, correlation_id: correlation_id
        }.compact)
      end

      return failure if failure

      Result.ok(protocol_definition: protocol)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
