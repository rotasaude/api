# app/commands/screenings/abandon.rb
# Abandonar a escuta (ADR 0030; spec §3.2): a pessoa volta à fila do
# acolhimento. release! é o mesmo efeito por dentro de outro comando que já
# travou o atendimento (chamada, saída): ordem de travas atendimento → escuta.
module Screenings
  class Abandon
    def self.call(screening:, by:)
      ApplicationRecord.transaction do
        attendance = Attendance.lock.find(screening.attendance_id)
        screening.lock!
        status, _link = Authorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(status) unless status == :ok
        next Result.fail(:not_in_progress) unless screening.status == "in_progress"

        abandon!(screening, by)
        Result.ok(screening: screening)
      end
    end

    def self.release!(attendance, by:)
      Screening.where(attendance_id: attendance.id, status: "in_progress").lock.each { |s| abandon!(s, by) }.size
    end

    def self.abandon!(screening, by)
      screening.update!(status: "abandoned")
      DomainEvents.publish("screening.abandoned", screening_id: screening.id, attendance_id: screening.attendance_id,
                                                  user_id: by.id)
    end
    private_class_method :abandon!
  end
end
