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
      # ANULÁVEL neste passo, de propósito: um argumento não-anulável faria o
      # console em produção — que ainda não manda nada — quebrar na validação
      # no instante em que este api subisse. Vira obrigatório no terceiro passo
      # do rollout (spec 2026-09-25 §5), com issue própria. O frontend não pôde
      # ir primeiro porque o GraphQL recusa argumento não declarado.
      argument :expected_version, Integer, required: false,
               description: "A versão que a tela via como vigente. Divergiu, a reversão é recusada."

      def resolve(city_slug:, name:, reason:, code:, expected_version: nil)
        in_city(city_slug: city_slug, step_up_code: code, event: "maintenance.protocol.reverted", module_name: "protocol",
                rejection_path: lambda { |result|
                  case result.reason
                  when :reason_required then "reason"
                  when :current_version_changed then "expectedVersion"
                  else "name"
                  end
                },
                protocol_key: name, reason_given: !reason.to_s.strip.empty?,
                changed_fields: [ "status" ],
                payload_from_result: ->(r) { { reverted_to_version: r.payload[:protocol_definition].version } }) do |actor, correlation_id|
          Protocols::RevertActivation.call(name: name, reason: reason, by: actor,
                                           expected_version: expected_version, correlation_id: correlation_id)
        end
      end
    end
  end
end
