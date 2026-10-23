# Inscrição (ADR 0040, Invariante: nenhuma sem confirmação de profissional).
# Quem chama com `by` é quem confirma: médico ou enfermeiro com vínculo na
# unidade da equipe. DUM só na linha que exige (lmp), entre hoje − 336 e
# hoje, gravada cifrada. Ordem de travas (Desvio 8): cidadão → sugestão →
# paciente → inscrição. A inscrição aceita TODAS as sugestões pendentes de
# inscrição da pessoa e da linha (a de encerramento nunca); `suggestion:`
# é a que o profissional decidiu aceitar e fica ligada à inscrição.
module CareLines
  module Enroll
    module_function

    def call(patient:, line:, team:, by:, anchor_date: nil, suggestion: nil, today: Time.zone.today)
      return Result.fail(:line_inactive) unless line.active
      return Result.fail(:cbo_not_allowed) unless Access.confirmer?(by, team)

      anchor = validate_anchor(line, anchor_date, today)
      return anchor if anchor.is_a?(Result)

      ApplicationRecord.transaction(requires_new: true) do
        # Paciente anonimizado pela exclusão LGPD não se inscreve (a mesma
        # conferência do Suggest). Ela trava os pares (FOR KEY SHARE): vem
        # antes das sugestões e do paciente, na ordem do Desvio 8 e do Erase
        # (pares → paciente).
        next Result.fail(:citizen_not_verified) if Suggest.anonymized_patient?(patient.id)

        pending = lock_pending(patient, line)
        linked = suggestion ? pending.find { |candidate| candidate.id == suggestion.id } : pending.first
        next Result.fail(:invalid_transition) if suggestion && linked.nil?

        patient.lock!
        enrollment = CareLineEnrollment.create!(patient: patient, care_line: line, team: team, enrolled_by_user: by, enrolled_at: Time.current,
                                                source: linked ? "suggestion" : "manual", suggestion: linked, anchor_date: anchor&.iso8601)
        DomainEvents.publish("care_line_enrollment.created", care_line_enrollment_id: enrollment.id, user_id: by.id)
        pending.each { |pending_suggestion| AcceptSuggestion.decide!(pending_suggestion, by) }
        Result.ok(enrollment: enrollment)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_enrolled)
    end

    # Âncora da inscrição (nil quando a linha não usa DUM) ou o Result da
    # recusa. Pública para quem recusa antes de gravar qualquer coisa.
    def validate_anchor(line, raw, today)
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

    # Sugestões de inscrição pendentes da pessoa (o paciente, os pares ligados
    # a ele ou os de mesmo CPF ainda sem paciente) nesta linha, travadas por
    # id: dois aceites concorrentes travam o mesmo conjunto na mesma ordem.
    # Só pares validados e não apagados: o par apagado pela exclusão LGPD (ou
    # rebaixado) nunca tem sugestão decidida nem pesa no aceite.
    def lock_pending(patient, line)
      base = CareLineSuggestion.pending_suggestions.where(care_line_id: line.id).where.not(reason: "resolved_problem")
      pairs = Citizen.not_erased.verification_level_verified
      pair_ids = pairs.where(patient_id: patient.id).or(pairs.where(cpf: patient.cpf)).select(:id)
      base.where(patient_id: patient.id).or(base.where(citizen_id: pair_ids)).order(:id).lock.to_a
    end
    private_class_method :lock_pending
  end
end
