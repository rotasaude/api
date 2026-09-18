# Aposenta uma versão de protocolo: → `retired`.
# Ver ADR-0009 (RetireProtocolVersion; guarda R4).
#
# `by:` é um User ou Maintenance::MaintainerActor. Regra inalterada pela spec
# de assinaturas: aposentar não exige assinatura de revisor.
#
# Invariante:
# - R4 / INV-protocol-4: não se aposenta uma versão `active`. Se a cidade ainda a
#   tem `active`, falha — a cidade deve migrar para outra versão antes. Nunca se
#   troca a versão vigente por baixo dos panos (perigoso em contexto clínico).
#
# Concorrência (I1): a leitura antes do lock pode estar obsoleta quando este
# command escreve — um Activate ou RevertActivation concorrente pode ter
# levado a MESMA versão a `active` entre a leitura e a escrita; sem re-conferir
# sob a trava, este command escreveria `retired` por cima da versão vigente da
# cidade (R4 violado, cidade sem active). Trava a linha (`lock!`) dentro da
# transação e reconfere o status no registro travado — só então decide e
# escreve. Mesmo padrão de Protocols::Activate/RevertActivation.
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|:active_in_city)
module Protocols
  module Retire
    def self.call(version:, by:, name: nil, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?

      scope = ProtocolDefinition.where(version: version)
      scope = scope.where(name: name) if name
      return Result.fail(:not_found) if scope.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if scope.count > 1

      protocol = scope.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).publish?

      # Fast fail on the un-locked read (avoids opening a transaction for the
      # common case); re-checked under the lock below, which is what actually
      # guards the race. ProtocolPolicy#publish? asks only the actor's role,
      # never the record, so it needs no re-check under the lock.
      if protocol.status == "active"
        return Result.fail(:active_in_city, message: "versão active não pode ser aposentada; migre a cidade para outra versão antes (R4)")
      end

      failure = nil
      ApplicationRecord.transaction do
        # A concurrent Activate (or RevertActivation) can move this same
        # version to "active" between the reads above and this write. Locking
        # and re-reading here is what closes that: status is re-run against
        # the locked row's actual current state, never the pre-lock read.
        protocol.lock!

        if protocol.status == "active"
          failure = Result.fail(:active_in_city,
                                message: "versão active não pode ser aposentada; migre a cidade para outra versão antes (R4)")
          raise ActiveRecord::Rollback
        end

        protocol.update!(status: "retired", retired_at: Time.current)

        DomainEvents.publish("protocol.retired", **{
          protocol_definition_id: protocol.id, protocol_key: protocol.name, version: protocol.version,
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
