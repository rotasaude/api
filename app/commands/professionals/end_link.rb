# Encerra o vínculo (ADR 0021): grava o fim, nunca apaga. FOR UPDATE na linha
# do vínculo: espera a chamada em curso (ClinicalAuthorization, FOR SHARE) e o
# lançamento de turno em curso (ScheduleShift, FOR SHARE).
module Professionals
  class EndLink
    def self.call(link:, by:)
      ApplicationRecord.transaction do
        link.lock!
        next Result.fail(:already_ended) unless link.active?

        link.update!(ended_at: Time.current, ended_by_user: by)
        cancelled_ids = cancel_future_shifts(link, by)
        DomainEvents.publish("professional.unlinked", professional_link_id: link.id, professional_id: link.professional_id,
                                                      health_unit_id: link.health_unit_id,
                                                      cancelled_shift_ids: cancelled_ids, by_user_id: by.id)
        Result.ok(link: link, cancelled_shift_ids: cancelled_ids)
      end
    end

    # Fatia 3 (Task 9) cancela aqui os turnos que ainda não começaram.
    def self.cancel_future_shifts(_link, _by) = []
  end
end
