module Maintenance
  module Mutations
    # Reversão de emergência (spec de assinaturas §6): volta a versão vigente
    # para a que estava em uso imediatamente antes, sem assinatura nova. O
    # motivo é texto livre de cidade — nunca vai para a auditoria de
    # plataforma (Decisão 4, global-constraints.md): platform_events é
    # governado pela Ruling R18, que não guarda conteúdo livre do cliente.
    # Só `reason_given` (booleano) entra na auditoria; o texto em si fica na
    # linha `emergency_revert` e no DomainEvent da própria cidade.
    class RevertProtocolActivation < CityMutation
      description "Reversão de emergência: volta a ativação da cidade para a versão anterior assinada, " \
                  "com motivo. Exige o TOTP do momento; o motivo fica na cidade, nunca na auditoria da plataforma."

      argument :name, String, required: true
      argument :reason, String, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, name:, reason:, code:)
        in_city(city_slug: city_slug, event: "maintenance.protocol.reverted", module_name: "protocol",
                rejection_path: "reason", protocol_key: name,
                reason_given: reason.to_s.strip.present?, changed_fields: [ "status" ]) do |actor, correlation_id|
          step_up!(code)
          Protocols::RevertActivation.call(name: name, reason: reason, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
