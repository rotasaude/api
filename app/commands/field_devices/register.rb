# Cadastra um aparelho de campo (módulo 24b, ADR 0052; contrato §9.1). A linha
# do usuário travada decide a corrida de dois cadastros contra o limite de 3
# ativos. Só quem tem vínculo ativo da Tabela 7 em equipe ativa 70/76
# (HomeVisits::Access.device_owner?); enfermeiro e médico → cbo_not_allowed.
# O token (FieldSync::Token) só existe nesta resposta: o banco guarda o
# SHA-256. Quem chama já conferiu o step-up. Evento só com ids.
#
# Substituição (módulo 24c, ADR 0053; contrato §1, Q16, Q17): com
# `replaces_device_id`, o aparelho ATIVO do próprio usuário é revogado (motivo
# replaced, com autor) e o novo nasce na mesma transação; o limite não conta o
# substituído. O revogado (inclusive o suspenso) não se substitui: cadastra-se
# de novo, pelo cadastro simples. O tablet antigo recebe 401 device_suspended.
#
# -> ok(device:, token:, replaced:) | fail(:invalid_request, path: "name" | "replaces_device_id") |
#    fail(:cbo_not_allowed) | fail(:device_limit)
module FieldDevices
  module Register
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(user:, name:, replaces_device_id: nil)
      name = name.strip if name.is_a?(String)
      return Result.fail(:invalid_request, details: { path: "name" }) unless name.is_a?(String) && FieldSync::Catalog::DEVICE_NAME.cover?(name.length)
      return not_replaceable unless replaces_device_id.nil? || (replaces_device_id.is_a?(String) && replaces_device_id.match?(UUID))

      User.transaction(requires_new: true) do
        user.lock!
        member = user.active? && HomeVisits::Access.device_owner?(user)
        next Result.fail(:cbo_not_allowed) unless member

        replaced = replaces_device_id && FieldDevice.active.find_by(id: replaces_device_id, user_id: user.id)
        next not_replaceable if replaces_device_id && !replaced

        active = FieldDevice.active.where(user_id: user.id).count - (replaced ? 1 : 0)
        next Result.fail(:device_limit) if active >= FieldSync::Catalog::MAX_ACTIVE_DEVICES
        # Outra requisição revogou o antigo entre a busca e a trava dele.
        next not_replaceable if replaced && Revoke.call(replaced, by: user, reason: "replaced").failure?

        token = FieldSync::Token.generate
        device = FieldDevice.create!(user: user, professional: user.professional, name: name, token_digest: FieldDevice.digest(token))
        DomainEvents.publish("field_device.registered", field_device_id: device.id, user_id: user.id)
        Result.ok(device: device, token: token, replaced: replaced || nil)
      end
    end

    def not_replaceable = Result.fail(:invalid_request, details: { path: "replaces_device_id" })
    private_class_method :not_replaceable
  end
end
