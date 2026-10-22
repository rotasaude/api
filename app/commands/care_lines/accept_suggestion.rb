# Aceitar sugestão (contrato §4). De inscrição: o paciente nasce por
# Patients::Resolve quando a sugestão é de par validado (antes de travar a
# sugestão: ordem cidadão → sugestão → paciente; Desvio 8) e a inscrição
# sai pelo Enroll (que confere quem confirma). De encerramento: encerra com
# discharge (quem tem o painel da equipe). Se a inscrição falha depois do
# Resolve, o paciente criado fica (é o mesmo que a primeira consulta criaria).
module CareLines
  module AcceptSuggestion
    module_function

    def call(suggestion:, by:, team: nil, anchor_date: nil, today: Time.zone.today)
      return close(suggestion, by) if suggestion.closure?

      team ||= suggestion.team
      return Result.fail(:cbo_not_allowed) unless Access.confirmer?(by, team)

      patient = suggestion.patient
      if patient.nil?
        resolved = Patients::Resolve.call(suggestion.citizen)
        return Result.fail(:citizen_not_verified) if resolved.failure?

        patient = resolved.payload[:patient]
      end

      ApplicationRecord.transaction do
        suggestion.lock!
        next Result.fail(:invalid_transition) unless suggestion.pending?

        enrolled = Enroll.call(patient: patient, line: suggestion.care_line, team: team, by: by, anchor_date: anchor_date,
                               suggestion: suggestion, today: today)
        next enrolled if enrolled.failure?

        decide!(suggestion, by)
        enrolled
      end
    end

    # Quem chama trava a sugestão e confere que está pendente.
    def decide!(suggestion, by)
      suggestion.update!(status: "accepted", decided_by_user: by, decided_at: Time.current)
      DomainEvents.publish("care_line_suggestion.accepted", care_line_suggestion_id: suggestion.id, user_id: by.id)
    end

    def close(suggestion, by)
      ApplicationRecord.transaction do
        suggestion.lock!
        next Result.fail(:invalid_transition) unless suggestion.pending?

        enrollment = suggestion.enrollment.lock!
        EndEnrollment.end!(enrollment, reason: "discharge", note: nil, by: by) if enrollment.active?
        # end! aceita as sugestões de encerramento pendentes da inscrição,
        # esta inclusive; só decide aqui se a inscrição já estava encerrada.
        decide!(suggestion, by) if suggestion.reload.pending?
        Result.ok(ended: enrollment)
      end
    end
    private_class_method :close
  end
end
