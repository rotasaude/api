# app/commands/integrations/set_credential.rb
# Cadastra ou troca a credencial de integração da cidade (ADR 0028; spec
# 2026-10-05 §3.3). Escrita só: nada devolve o segredo. Trocar zera o último
# teste (a credencial nova nunca foi testada). O evento leva só kind e user_id.
# Reasons: :unknown_kind, :invalid_credential.
module Integrations
  module SetCredential
    module_function

    def call(kind:, username:, password:, by:)
      return Result.fail(:unknown_kind) unless IntegrationCredential::KINDS.include?(kind)
      return Result.fail(:invalid_credential) unless [ username, password ].all? { |v| filled?(v) }

      credential = nil
      ApplicationRecord.transaction do
        credential = IntegrationCredential.lock.find_or_initialize_by(kind: kind)
        credential.update!(secret: { "username" => username.strip, "password" => password }, set_by_user: by,
                           set_at: Time.current, last_check_at: nil, last_check_status: nil, last_check_message: nil)
        DomainEvents.publish("integration_credential.changed", kind: kind, user_id: by.id)
      end
      Result.ok(credential: credential)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def filled?(value) = value.is_a?(String) && value.strip.present? && value.length <= IntegrationCredential::FIELD_MAX
  end
end
