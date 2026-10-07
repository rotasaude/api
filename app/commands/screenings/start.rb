# app/commands/screenings/start.rb
# Iniciar a escuta (ADR 0030; spec §3.2). Trava o atendimento: duas
# profissionais ao mesmo tempo, uma inicia e a outra recebe already_screening.
# Escuta abandonada do mesmo atendimento é retomada (uma por atendimento).
module Screenings
  class Start
    def self.call(attendance:, by:)
      ApplicationRecord.transaction do
        attendance.lock!
        status, link = Authorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(status) unless status == :ok
        next Result.fail(:not_waiting) unless attendance.status == "waiting"
        next Result.fail(:screening_not_required) unless Scope.required?(attendance)

        screening = Screening.lock.find_by(attendance_id: attendance.id)
        next Result.fail(:already_screening) if screening && screening.status != "abandoned"

        attrs = { status: "in_progress", started_by_user: by, professional_link: link, cbo_code: link.cbo_code,
                  started_at: Time.current }
        screening ? screening.update!(attrs) : (screening = Screening.create!(attrs.merge(attendance: attendance)))
        DomainEvents.publish("screening.started", screening_id: screening.id, attendance_id: attendance.id, user_id: by.id)
        Result.ok(screening: screening)
      end
    end
  end
end
