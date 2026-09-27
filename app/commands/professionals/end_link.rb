# Encerra o vínculo (ADR 0021): grava o fim, nunca apaga. FOR UPDATE na linha
# do vínculo: espera a chamada em curso (ClinicalAuthorization, FOR SHARE) e o
# lançamento de turno em curso (ScheduleShift, FOR SHARE).
module Professionals
  class EndLink
    def self.call(link:, by:)
      ApplicationRecord.transaction do
        link.lock!
        next Result.fail(:already_ended) unless link.active?

        # Relógios divergentes entre hosts podem fazer Time.current cair antes
        # de started_at (gravado por outro host); nunca menos que started_at,
        # senão viola ck_professional_links_order.
        link.update!(ended_at: [ Time.current, link.started_at ].max, ended_by_user: by)
        cancelled_ids = cancel_future_shifts(link, by)
        DomainEvents.publish("professional.unlinked", professional_link_id: link.id, professional_id: link.professional_id,
                                                      health_unit_id: link.health_unit_id,
                                                      cancelled_shift_ids: cancelled_ids, by_user_id: by.id)
        Result.ok(link: link, cancelled_shift_ids: cancelled_ids)
      end
    end

    # Turnos que ainda não começaram (D8): "não existe turno em vínculo
    # encerrado". O passado e o em curso ficam — valiam quando começaram.
    def self.cancel_future_shifts(link, by)
      now = link.ended_at
      link.shifts.valid_shifts.where("starts_at > ?", now).lock.order(:starts_at).map do |shift|
        shift.update!(cancelled_at: now, cancelled_by_user: by, cancel_reason: ProfessionalShift::LINK_ENDED_REASON)
        shift.id
      end
    end
  end
end
