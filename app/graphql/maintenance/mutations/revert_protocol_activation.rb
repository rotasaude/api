module Maintenance
  module Mutations
    # Reversão de emergência (spec de assinaturas §6): volta a versão vigente
    # para a que estava em uso imediatamente antes, sem assinatura nova. O
    # motivo é texto livre de cidade — nunca vai para a auditoria de
    # plataforma (Decisão 4, global-constraints.md): platform_events é
    # governado pela Ruling R18, que não guarda conteúdo livre do cliente.
    # Só `reason_given` (booleano) entra na auditoria; o texto em si fica na
    # linha `emergency_revert` e no DomainEvent da própria cidade.
    #
    # `reason_given` usa EXATAMENTE a regra do command (`strip.empty?`, que não
    # remove U+00A0): a auditoria diz "houve motivo" exatamente quando o
    # command passou da checagem de motivo — nunca uma regra própria que
    # divirja dela (`present?` divergia em U+00A0). A recusa só vai
    # para `reason` quando é do motivo; qualquer outra (nada a reverter, versão
    # anterior indisponível) é do protocolo, `name`.
    class RevertProtocolActivation < CityMutation
      description "Reversão de emergência: volta a ativação da cidade para a versão anterior assinada, " \
                  "com motivo. Exige o TOTP do momento; o motivo fica na cidade, nunca na auditoria da plataforma."

      # O número que passou a valer. Vem do Result do command — o que a tela
      # afirma é o que ele decidiu sob lock, nunca uma releitura depois do ato.
      # Int como `version` já é nos tipos de manutenção; nulo quando a mutation
      # não chegou a reverter.
      field :reverted_to_version, Integer, null: true

      argument :name, String, required: true
      argument :reason, String, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, name:, reason:, code:)
        in_city(city_slug: city_slug, step_up_code: code, event: "maintenance.protocol.reverted", module_name: "protocol",
                rejection_path: ->(result) { result.reason == :reason_required ? "reason" : "name" },
                protocol_key: name, reason_given: !reason.to_s.strip.empty?,
                changed_fields: [ "status" ],
                payload: ->(result) { { reverted_to_version: result.payload[:protocol_definition].version } }) do |actor, correlation_id|
          Protocols::RevertActivation.call(name: name, reason: reason, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
