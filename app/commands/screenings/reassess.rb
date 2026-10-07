# app/commands/screenings/reassess.rb
# Reavaliar enquanto a pessoa espera (ADR 0030; spec §3.2): só escuta
# concluída com destino same_day e atendimento ainda waiting. Nova revisão
# vira a corrente; a cor nova reordena a fila do profissional.
module Screenings
  class Reassess
    def self.call(screening:, revision_params:, by:)
      attendance = screening.attendance
      input = RevisionInput.call(revision_params, citizen: attendance.citizen)
      return input if input.failure?

      ApplicationRecord.transaction do
        attendance.lock!
        screening.lock!
        status, link = Authorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(status) unless status == :ok
        unless screening.status == "completed" && screening.destination == "same_day" && attendance.status == "waiting"
          next Result.fail(:not_reassessable)
        end

        revision = ScreeningRevision.create!(input.payload[:attrs].merge(screening: screening, by_user: by))
        screening.update!(current_revision: revision, professional_link: link, cbo_code: link.cbo_code)
        DomainEvents.publish("screening.reassessed", screening_id: screening.id, revision_id: revision.id,
                                                     final_color: revision.final_color)
        Result.ok(screening: screening, revision: revision)
      end
    end
  end
end
