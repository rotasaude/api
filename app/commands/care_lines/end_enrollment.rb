# Saída com motivo (contrato §1 e §4): uma vez; a nota (opcional, até 500)
# cifrada. A sugestão de encerramento pendente da inscrição fica aceita por
# quem encerrou. Ordem de travas (Desvio 8; errata C-api-02): sugestões de
# encerramento → inscrição (a mesma de quem aceita a sugestão).
module CareLines
  module EndEnrollment
    module_function

    def call(enrollment:, reason:, note:, by:)
      return Result.fail(:invalid_reason) unless Catalog::END_REASONS.include?(reason)

      text = note.is_a?(String) ? note.strip.presence : nil
      return Result.fail(:too_long, details: { field: "note" }) if text && text.length > Catalog::TEXT_MAX

      ApplicationRecord.transaction do
        CareLineSuggestion.pending_suggestions.where(enrollment_id: enrollment.id).order(:id).lock.to_a
        enrollment.lock!
        next Result.fail(:invalid_transition) unless enrollment.active?

        end!(enrollment, reason: reason, note: text, by: by)
        Result.ok(enrollment: enrollment)
      end
    end

    # Quem chama trava as sugestões de encerramento e a inscrição, nessa
    # ordem, e confere que está ativa.
    def end!(enrollment, reason:, note:, by:)
      enrollment.update!(status: "ended", ended_reason: reason, ended_note: note, ended_at: Time.current, ended_by_user: by)
      CareLineSuggestion.pending_suggestions.where(enrollment_id: enrollment.id).find_each do |closure|
        AcceptSuggestion.decide!(closure, by)
      end
      DomainEvents.publish("care_line_enrollment.ended", care_line_enrollment_id: enrollment.id, user_id: by.id)
    end
  end
end
