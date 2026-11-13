# Cadastra um aparelho de campo (módulo 24b, ADR 0052; contrato §9.1). A linha
# do usuário travada decide a corrida de dois cadastros contra o limite de 3
# ativos. Só quem tem vínculo ativo da Tabela 7 em equipe ativa 70/76
# (HomeVisits::Access.device_owner?); enfermeiro e médico → cbo_not_allowed.
# O token (FieldSync::Token) só existe nesta resposta: o banco guarda o
# SHA-256. Quem chama já conferiu o step-up. Evento só com ids.
#
# -> ok(device:, token:) | fail(:invalid_request, path: "name") |
#    fail(:cbo_not_allowed) | fail(:device_limit)
module FieldDevices
  module Register
    module_function

    def call(user:, name:)
      name = name.strip if name.is_a?(String)
      return Result.fail(:invalid_request, details: { path: "name" }) unless name.is_a?(String) && FieldSync::Catalog::DEVICE_NAME.cover?(name.length)

      User.transaction(requires_new: true) do
        user.lock!
        member = user.active? && HomeVisits::Access.device_owner?(user)
        next Result.fail(:cbo_not_allowed) unless member
        next Result.fail(:device_limit) if FieldDevice.active.where(user_id: user.id).count >= FieldSync::Catalog::MAX_ACTIVE_DEVICES

        token = FieldSync::Token.generate
        device = FieldDevice.create!(user: user, professional: user.professional, name: name, token_digest: FieldDevice.digest(token))
        DomainEvents.publish("field_device.registered", field_device_id: device.id, user_id: user.id)
        Result.ok(device: device, token: token)
      end
    end
  end
end
