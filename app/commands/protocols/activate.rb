# Ativa uma versão `published` como a vigente (`active`) da cidade.
# Ver ADR-0009 (lifecycle de dois eixos; ActivateProtocolVersion).
#
# Invariantes:
# - R1 / INV-protocol-1: só uma versão `published` pode virar `active`.
# - INV-protocol-2: uma `active` por (municipality_id, name) — a versão `active`
#   anterior do mesmo protocolo é demovida de volta a `published` no mesmo átomo,
#   e a unique parcial WHERE status='active' garante a unicidade.
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|:not_published)
module Protocols
  module Activate
    def self.call(version:, by:, name: nil)
      return Result.fail(:tenant_missing) if Current.municipality_id.nil?

      scope = ProtocolDefinition.where(municipality_id: Current.municipality_id, version: version)
      scope = scope.where(name: name) if name
      return Result.fail(:not_found) if scope.empty?
      return Result.fail(:ambiguous, message: "multiple protocols match version #{version}") if scope.count > 1

      protocol = scope.first
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).activate?
      unless protocol.status == "published"
        return Result.fail(:not_published, message: "só versão published pode ser ativada (R1; está #{protocol.status})")
      end

      ApplicationRecord.transaction do
        # demove a active anterior do mesmo protocolo ANTES de ativar a nova,
        # para a unique parcial WHERE status='active' nunca ver duas active.
        ProtocolDefinition
          .where(municipality_id: Current.municipality_id, name: protocol.name, status: "active")
          .where.not(id: protocol.id)
          .update_all(status: "published")

        protocol.update!(status: "active", activated_at: Time.current)

        DomainEvents.publish(
          "protocol.activated",
          municipality_id: Current.municipality_id,
          protocol_key: protocol.name,
          protocol_definition_id: protocol.id,
          version: protocol.version,
          activated_by: by.id
        )
      end

      Result.ok(protocol_definition: protocol)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
