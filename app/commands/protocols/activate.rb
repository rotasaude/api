# Ativa uma versão `published` como a vigente (`active`) da cidade, com duas
# assinaturas de ativação válidas (spec de assinaturas §4/§5).
# Ver ADR-0009 (lifecycle de dois eixos; ActivateProtocolVersion).
#
# `by:` é um User (protocol_publisher ou municipal_admin) ou
# Maintenance::MaintainerActor — o mantenedor ativa quando as assinaturas da
# cidade já existem, nunca antes (D6: ele responde "sim" a ProtocolPolicy, mas
# não assina). Step-up MFA é do chamador (ADR-0011), como em Publish.
#
# Invariantes:
# - R1 / INV-protocol-1: só uma versão `published` pode virar `active`.
# - INV-protocol-2: uma `active` por name (o banco é da cidade) — a versão `active`
#   anterior do mesmo protocolo é demovida de volta a `published` no mesmo átomo,
#   e a unique parcial WHERE status='active' garante a unicidade.
#
# O ato grava ProtocolActivation(kind: "signed") na mesma transação — a
# assinatura de ativação é consumida a partir daí (Protocols::Signatures só
# conta assinaturas posteriores à última ativação da versão), então reativar a
# mesma versão depois pede assinaturas novas. Os signatários são lidos ANTES
# do ProtocolActivation.create!: depois dele a assinatura já está consumida e
# a lista viria vazia.
#
# Concorrência: a leitura antes do lock pode estar obsoleta quando este
# command escreve (por exemplo, um Retire concorrente movendo a mesma versão
# para `retired`). Trava a linha (`lock!`) dentro da transação e reconfere
# status e assinaturas no registro travado — só então decide e escreve.
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|
#   :not_published|:signatures_missing)
module Protocols
  module Activate
    def self.call(version:, by:, name: nil, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?

      conditions = { version: version }
      conditions[:name] = name if name
      scope = ProtocolDefinition.where(conditions)
      return Result.fail(:not_found) if scope.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if scope.count > 1

      protocol = scope.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).activate?

      # Fast fail on the un-locked read (avoids opening a transaction and
      # querying signatures for the common case); re-checked under the lock
      # below, which is what actually guards the race. ProtocolPolicy#activate?
      # asks only the actor's role, never the record, so it needs no re-check
      # under the lock.
      unless protocol.status == "published"
        return Result.fail(:not_published, message: "só versão published pode ser ativada (R1; está #{protocol.status})")
      end

      if Signatures.missing(protocol, purpose: "activation").positive?
        return Result.fail(:signatures_missing, message: Signatures.shortfall_message(protocol, purpose: "activation"))
      end

      failure = nil
      ApplicationRecord.transaction do
        # A concurrent Retire (or another Activate) can move this same
        # version out of "published" between the reads above and this write.
        # Locking and re-reading here is what closes that: status and
        # Signatures are both re-run against the locked row's actual current
        # state, never the pre-lock read.
        protocol.lock!

        unless protocol.status == "published"
          failure = Result.fail(:not_published,
                                message: "só versão published pode ser ativada (R1; está #{protocol.status})")
          raise ActiveRecord::Rollback
        end

        if Signatures.missing(protocol, purpose: "activation").positive?
          failure = Result.fail(:signatures_missing,
                                message: Signatures.shortfall_message(protocol, purpose: "activation"))
          raise ActiveRecord::Rollback
        end

        # Read before ProtocolActivation.create! below — once that row lands,
        # it is itself the "last activation" Signatures checks against, and
        # the very signatures that justified this act would read as already
        # consumed.
        signers = Signatures.valid_signer_ids(protocol, purpose: "activation")

        # demove a active anterior do mesmo protocolo ANTES de ativar a nova,
        # para a unique parcial WHERE status='active' nunca ver duas active.
        ProtocolDefinition
          .where(name: protocol.name, status: "active")
          .where.not(id: protocol.id)
          .update_all(status: "published")

        protocol.update!(status: "active", activated_at: Time.current)

        ProtocolActivation.create!(protocol_definition: protocol, kind: "signed",
                                   actor_id: by.id, actor_kind: by.actor_kind)

        DomainEvents.publish("protocol.activated", **{
          protocol_key: protocol.name, protocol_definition_id: protocol.id, version: protocol.version,
          signers: signers, activated_by: by.id, actor_kind: by.actor_kind, correlation_id: correlation_id
        }.compact)
      end

      return failure if failure

      Result.ok(protocol_definition: protocol)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
