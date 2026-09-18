module Maintenance
  module Mutations
    class CreateMaintenanceToken < BaseMutation
      description "Cria um token de serviço. O segredo volta UMA vez, em secretOnce."

      argument :name, String, required: true
      argument :access, String, required: true
      argument :city_slugs, [ String ], required: false, default_value: []
      argument :expires_at, GraphQL::Types::ISO8601DateTime, required: true
      argument :code, String, required: true, description: "TOTP do momento: um token é um login que não expira em 8h"

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      # Nome explícito e declarado na guarda de schema: o valor existe uma vez e
      # nunca é gravado. Chamá-lo de `token` ou `secret` esbarraria — com razão —
      # na guarda de nomes proibidos.
      field :secret_once, String, null: true

      def resolve(name:, access:, city_slugs:, expires_at:, code:)
        secret = nil

        # `token_label`, não `token_name`: a Ruling R18 recusa QUALQUER chave de
        # payload que contenha "name" (o fragmento existe para barrar nome de
        # pessoa), e PlatformEvent levantaria na gravação da tentativa.
        result = audited(event: "maintenance.token.created", module_name: "token", token_label: name.to_s.strip) do
          # Step-up: a sessão já está verificada, mas criar token é emitir uma
          # credencial de longa vida (spec §7). O bloqueio de conta, a
          # auditoria da falha e o consumo do código moram em `step_up!`.
          step_up!(code)

          record, secret = MaintenanceToken.issue!(maintainer: credential.maintainer, name: name, access: access,
                                                   city_slugs: city_slugs, expires_at: expires_at)
          record
        rescue ActiveRecord::RecordInvalid => e
          raise Rejected.new(e.record.errors.full_messages.to_sentence, path: e.record.errors.attribute_names.first.to_s.camelize(:lower))
        end

        result.merge(secret_once: secret)
      end
    end
  end
end
