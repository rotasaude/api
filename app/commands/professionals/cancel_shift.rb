# Cancela um turno (ADR 0021): grava hora, quem e motivo; nunca apaga.
module Professionals
  class CancelShift
    def self.call(shift:, reason:, by:)
      reason = reason.to_s.strip
      return Result.fail(:reason_required) if reason.empty?
      return Result.fail(:reason_too_long) if reason.length > ProfessionalShift::MAX_REASON

      ApplicationRecord.transaction do
        shift.lock!
        next Result.fail(:already_cancelled) if shift.cancelled_at

        shift.update!(cancelled_at: Time.current, cancelled_by_user: by, cancel_reason: reason)
        DomainEvents.publish("professional.shift_cancelled", shift_id: shift.id, professional_id: shift.professional_id,
                                                             professional_link_id: shift.professional_link_id,
                                                             by_user_id: by.id)
        Result.ok(shift: shift)
      end
    end
  end
end
