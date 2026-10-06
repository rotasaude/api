# Fila "sem unidade" (ADR 0029 §5.3; contratos §4.1, §10): o pedido sem
# unidade de destino recebe uma unidade ativa UMA vez (o trigger aceita só
# NULL → unidade). Unidade FOR SHARE primeiro, depois o pedido (a ordem de
# Placement.lock! e do Drain).
module AppointmentRequests
  module AssignUnit
    UUID = /\A\h{8}-(\h{4}-){3}\h{12}\z/

    module_function

    def call(request:, unit_id:, by:)
      return Result.fail(:invalid_unit) unless unit_id.to_s.match?(UUID)

      ApplicationRecord.transaction do
        unit = HealthUnit.lock_active!(unit_id.to_s)
        request.lock!
        next Result.fail(:already_assigned) unless request.target_unit_id.nil?
        next Result.fail(:request_not_open) unless request.status == "open"

        request.update!(target_unit: unit)
        DomainEvents.publish("appointment_request.unit_assigned", request_id: request.id, unit_id: unit.id,
                                                                  by_user_id: by.id)
        Result.ok(request: request)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end
  end
end
