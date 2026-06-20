# Publica uma versão de protocolo no município atual (ADR-0016 + ADR-0023).
#
# Pré-requisitos:
# - Current.municipality_id setado (within_tenant do request — ADR-0019).
# - Step-up MFA conferido pelo controller (ADR-0022).
#
# Comportamento:
# - Encontra ProtocolDefinition por (current_municipality, version).
# - Autoriza via ProtocolPolicy (Phase 4.4).
# - Aposenta a versão active anterior do mesmo nome (1 active por nome/cidade).
# - Marca a versão alvo como active + activated_at.
# - Audita via DomainEvents.publish("protocol.published", ...).
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|:invalid)
module Protocols
  module Publish
    def self.call(version:, by:)
      return Result.fail(:tenant_missing) if Current.municipality_id.nil?

      candidates = ProtocolDefinition.where(
        municipality_id: Current.municipality_id,
        version: version
      )
      return Result.fail(:not_found) if candidates.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if candidates.count > 1

      protocol = candidates.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).publish?

      ApplicationRecord.transaction do
        ProtocolDefinition
          .where(municipality_id: Current.municipality_id, name: protocol.name, status: "active")
          .where.not(id: protocol.id)
          .update_all(status: "retired", retired_at: Time.current)

        protocol.update!(status: "active", activated_at: Time.current)

        DomainEvents.publish(
          "protocol.published",
          protocol_definition_id: protocol.id,
          name: protocol.name,
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
