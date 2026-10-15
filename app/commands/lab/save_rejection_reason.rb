# Motivo de rejeição de amostra (contrato §3): nome único por laboratório
# (sem diferença de caixa); `active` ausente mantém o atual (novo = ativo).
module Lab
  module SaveRejectionReason
    module_function

    def call(params, reason: nil)
      params = params.to_h.stringify_keys
      name = params["name"].is_a?(String) ? params["name"].strip : ""
      return Result.fail(:invalid_name) unless name.length.between?(1, 80)

      active = params.key?("active") ? params["active"] : (reason ? reason.active : true)
      return Result.fail(:invalid_active) unless [ true, false ].include?(active)

      reason ||= LabRejectionReason.new(exam_provider_id: params["provider_id"])
      reason.update!(name: name, active: active)
      Result.ok(reason: reason)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_name)
    end
  end
end
