# Aposenta uma versão de protocolo: → `retired`.
# Ver ADR-0009 (RetireProtocolVersion; guarda R4).
#
# Invariante:
# - R4 / INV-protocol-4: não se aposenta uma versão `active`. Se a cidade ainda a
#   tem `active`, falha — a cidade deve migrar para outra versão antes. Nunca se
#   troca a versão vigente por baixo dos panos (perigoso em contexto clínico).
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|:active_in_city)
module Protocols
  module Retire
    def self.call(version:, by:, name: nil)
      return Result.fail(:tenant_missing) if Current.municipality_id.nil?

      scope = ProtocolDefinition.where(municipality_id: Current.municipality_id, version: version)
      scope = scope.where(name: name) if name
      return Result.fail(:not_found) if scope.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if scope.count > 1

      protocol = scope.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).publish?
      if protocol.status == "active"
        return Result.fail(:active_in_city, message: "versão active não pode ser aposentada; migre a cidade para outra versão antes (R4)")
      end

      ApplicationRecord.transaction do
        protocol.update!(status: "retired", retired_at: Time.current)

        DomainEvents.publish(
          "protocol.retired",
          protocol_definition_id: protocol.id,
          protocol_key: protocol.name,
          version: protocol.version,
          actor: by.id
        )
      end

      Result.ok(protocol_definition: protocol)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
