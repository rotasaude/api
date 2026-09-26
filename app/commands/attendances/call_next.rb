# "Chamar próximo": o primeiro da fila; se outro profissional levou esse
# no mesmo instante, tenta o seguinte.
module Attendances
  class CallNext
    ATTEMPTS = 3

    def self.call(health_unit_id:, by:)
      ATTEMPTS.times do
        candidate = UnitQueue.waiting(health_unit_id).first
        return Result.fail(:queue_empty) unless candidate

        result = Call.call(attendance: candidate, health_unit_id: health_unit_id, by: by)
        return result unless result.failure? && result.reason == :already_called
      end
      Result.fail(:already_called)
    end
  end
end
