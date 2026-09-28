# Chamada (spec 2026-09-25 §2.1): waiting → in_care, sob lock. Exige papel e
# vínculo ativo com a unidade do atendimento (ADR 0021; F-10.5).
module Attendances
  class Call
    def self.call(attendance:, health_unit_id:, by:)
      return Result.fail(:wrong_unit) unless attendance.health_unit_id == health_unit_id.to_s

      state = ApplicationRecord.transaction do
        attendance.lock!
        authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next authorization unless authorization == :ok
        next :already_called unless attendance.status == "waiting"

        attendance.update!(status: "in_care", called_by_user: by, called_at: Time.current)
        DomainEvents.publish("attendance.called", attendance_id: attendance.id, called_by_user_id: by.id)
        :ok
      end
      state == :ok ? Result.ok(attendance: attendance) : Result.fail(state)
    end
  end
end
