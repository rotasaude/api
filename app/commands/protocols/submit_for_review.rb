# Envia um rascunho para revisão: draft → in_review (spec de assinaturas §4).
# É só em in_review que se assina a publicação. O portão roda aqui para que
# revisores não gastem assinatura num protocolo que a publicação recusaria.
#
# Result.ok(protocol_definition:) | Result.fail(:not_found|:forbidden|:invalid_state|:invalid)
module Protocols
  module SubmitForReview
    def self.call(name:, version:, by:, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?

      protocol = ProtocolDefinition.find_by(name: name, version: version)
      return Result.fail(:not_found) if protocol.nil?
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, protocol).author?
      unless protocol.status == "draft"
        return Result.fail(:invalid_state, message: "só rascunho vai para revisão (está #{protocol.status})")
      end

      gate = Protocols::Gate.call(protocol.definition)
      return Result.fail(:invalid, message: gate.errors.join("; ")) unless gate.valid?

      ApplicationRecord.transaction do
        protocol.update!(status: "in_review")
        DomainEvents.publish("protocol.submitted_for_review", **{
          protocol_definition_id: protocol.id, protocol_key: protocol.name, version: protocol.version,
          content_digest: protocol.content_digest, actor: by.id, actor_kind: by.actor_kind,
          correlation_id: correlation_id
        }.compact)
      end

      Result.ok(protocol_definition: protocol)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end
  end
end
