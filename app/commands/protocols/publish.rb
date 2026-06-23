# Publica uma versão de protocolo: move `draft`/`in_review` → `published`.
# Ver ADR-0009 (lifecycle de dois eixos: publish ≠ activate).
#
# Pré-requisitos:
# - Current.municipality_id setado (within_tenant do request — ADR-0003).
# - Step-up MFA conferido pelo controller (ADR-0011).
#
# Comportamento:
# - Encontra ProtocolDefinition por (current_municipality, version).
# - Autoriza via ProtocolPolicy (protocol_publisher).
# - Move a versão alvo para `published` (NÃO `active` — vigência é ato à parte,
#   ver Protocols::Activate). `published` ≠ `active`.
# - Audita via DomainEvents.publish("protocol.published", ...).
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:ambiguous|:forbidden|:invalid_state|:invalid)
module Protocols
  module Publish
    PUBLISHABLE_FROM = %w[draft in_review].freeze

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
      unless PUBLISHABLE_FROM.include?(protocol.status)
        return Result.fail(:invalid_state, message: "só draft/in_review pode ser publicado (está #{protocol.status})")
      end

      ApplicationRecord.transaction do
        protocol.update!(status: "published")

        DomainEvents.publish(
          "protocol.published",
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
