# POST/PATCH /ombudsman/responders (ADR 0051; contrato §7): quem responde os
# encaminhamentos de um destino. Criar: `user_id` com o papel
# `ombudsman_responder` ativo (senão 422 missing_responder_role, path user_id),
# exatamente um destino (`department_id` | `health_unit_id`) ativo; par
# (usuário, destino) repetido, mesmo desligado → 409 already_responder
# (desligar é `active = false`, religar é o PATCH). Editar: só `active`.
module Ombudsman
  module SaveResponder
    module_function

    # responder: nil cria. -> Result.ok(responder:) | fail(:invalid_request | :missing_responder_role, details: { path:, problems: }) |
    #    fail(:already_responder)
    def call(responder:, attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      responder ? update(responder, attrs) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_responder)
    end

    def update(responder, attrs)
      return failure("active") unless [ true, false ].include?(attrs["active"])

      responder.update!(active: attrs["active"])
      Result.ok(responder: responder)
    end

    def create(attrs, by)
      user_id = attrs["user_id"]
      return failure("user_id") unless Input.uuid?(user_id)

      keys = %w[department_id health_unit_id].select { |key| attrs[key].present? }
      return failure(attrs.key?("health_unit_id") ? "health_unit_id" : "department_id") unless keys.one?

      key = keys.first
      destination = destination_for(key, attrs[key])
      return failure(key) unless destination&.active

      user = User.find_by(id: user_id, deactivated_at: nil)
      return failure("user_id", :missing_responder_role) unless user && Access.responder?(user)
      return Result.fail(:already_responder) if OmbudsmanResponder.exists?(:user_id => user.id, key => destination.id)

      OmbudsmanResponder.transaction(requires_new: true) do
        Result.ok(responder: OmbudsmanResponder.create!(user: user, key.delete_suffix("_id") => destination, created_by_user: by))
      end
    end

    def destination_for(key, id)
      return nil unless Input.uuid?(id)

      (key == "department_id" ? Department : HealthUnit).find_by(id: id)
    end

    def failure(path, error = :invalid_request)
      Result.fail(error, details: { path: path, problems: [ { error: error.to_s, path: path } ] })
    end

    private_class_method :update, :create, :destination_for, :failure
  end
end
