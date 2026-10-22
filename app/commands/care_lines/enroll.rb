# Inscrição (ADR 0040, Invariante: nenhuma sem confirmação de profissional).
# Quem chama com `by` é quem confirma: médico ou enfermeiro com vínculo na
# unidade da equipe. DUM só na linha que exige (lmp), entre hoje − 336 e
# hoje, gravada cifrada. Ordem de travas (Desvio 8): cidadão → sugestão →
# paciente → inscrição. Inscrição à mão aceita a sugestão pendente de
# inscrição da mesma pessoa e linha (a de encerramento nunca).
module CareLines
  module Enroll
    module_function

    def call(patient:, line:, team:, by:, anchor_date: nil, suggestion: nil, today: Time.zone.today)
      return Result.fail(:line_inactive) unless line.active
      return Result.fail(:cbo_not_allowed) unless Access.confirmer?(by, team)

      anchor = parse_anchor(line, anchor_date, today)
      return anchor if anchor.is_a?(Result)

      enrollment = nil
      ApplicationRecord.transaction(requires_new: true) do
        # Quem aceita uma sugestão já a travou e decide por ela.
        pending = suggestion ? [] : lock_pending(patient, line)
        patient.lock!
        linked = suggestion || pending.first
        enrollment = CareLineEnrollment.create!(patient: patient, care_line: line, team: team, enrolled_by_user: by, enrolled_at: Time.current,
                                                source: linked ? "suggestion" : "manual", suggestion: linked, anchor_date: anchor&.iso8601)
        DomainEvents.publish("care_line_enrollment.created", care_line_enrollment_id: enrollment.id, user_id: by.id)
        pending.each { |pending_suggestion| AcceptSuggestion.decide!(pending_suggestion, by) }
      end
      Result.ok(enrollment: enrollment)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_enrolled)
    end

    def parse_anchor(line, raw, today)
      unless line.requires_lmp?
        return raw.nil? || raw == "" ? nil : Result.fail(:invalid_anchor)
      end
      return Result.fail(:anchor_required) if raw.nil? || raw == ""

      date = raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(raw) : nil
      return Result.fail(:invalid_anchor) unless date && date <= today && date >= today - Catalog::LMP_MAX_AGE_DAYS

      date
    rescue Date::Error
      Result.fail(:invalid_anchor)
    end

    # Sugestões de inscrição pendentes da pessoa (o paciente ou qualquer par
    # dele) nesta linha, travadas por id para a ordem ser a mesma em quem
    # trava mais de uma.
    def lock_pending(patient, line)
      base = CareLineSuggestion.pending_suggestions.where(care_line_id: line.id).where.not(reason: "resolved_problem")
      base.where(patient_id: patient.id).or(base.where(citizen_id: Citizen.where(patient_id: patient.id).select(:id))).order(:id).lock.to_a
    end
    private_class_method :parse_anchor, :lock_pending
  end
end
