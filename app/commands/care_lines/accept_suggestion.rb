# Aceitar sugestão (contrato §4). De inscrição: as recusas puras
# (line_inactive, âncora, sugestão já decidida, já inscrito) vêm ANTES do
# Patients::Resolve e sem trava, para a recusa não gravar nada (paciente,
# vínculo do par, evento); o Enroll as refaz sob trava. Depois o paciente
# nasce por Resolve quando a sugestão é de par validado (ordem cidadão →
# sugestão → paciente; Desvio 8) e a inscrição sai pelo Enroll, que confere
# quem confirma, trava TODAS as sugestões pendentes da pessoa e linha e as
# aceita. De encerramento: encerra com discharge (quem tem o painel da
# equipe). Se o Enroll falha depois do Resolve (corrida), o paciente criado
# fica (é o mesmo que a primeira consulta criaria).
module CareLines
  module AcceptSuggestion
    module_function

    def call(suggestion:, by:, team: nil, anchor_date: nil, today: Time.zone.today)
      return close(suggestion, by) if suggestion.closure?

      team ||= suggestion.team
      return Result.fail(:cbo_not_allowed) unless Access.confirmer?(by, team)

      line = suggestion.care_line
      return Result.fail(:line_inactive) unless line.active

      anchor = Enroll.validate_anchor(line, anchor_date, today)
      return anchor if anchor.is_a?(Result)
      return Result.fail(:invalid_transition) unless suggestion.reload.pending?

      known_patient_id = suggestion.patient_id || known_patient_of(suggestion.citizen)
      enrolled_already = known_patient_id && CareLineEnrollment.active_enrollments.exists?(patient_id: known_patient_id, care_line_id: line.id)
      return Result.fail(:already_enrolled) if enrolled_already

      patient = suggestion.patient
      if patient.nil?
        resolved = Patients::Resolve.call(suggestion.citizen)
        return Result.fail(:citizen_not_verified) if resolved.failure?

        patient = resolved.payload[:patient]
      end

      enrolled = Enroll.call(patient: patient, line: line, team: team, by: by, anchor_date: anchor_date, suggestion: suggestion, today: today)
      suggestion.reload if enrolled.ok?
      enrolled
    end

    # O paciente do par: o ligado ou, sem vínculo, o do CPF (o Resolve o
    # ligaria) — a recusa barata não liga o par antes de recusar. Pública: a
    # inscrição manual (EnrollmentsController#create) usa a mesma regra.
    def known_patient_of(citizen)
      return nil unless citizen

      citizen.patient_id || Patient.where(cpf: citizen.cpf).pick(:id)
    end

    # Quem chama trava a sugestão e confere que está pendente (Enroll e EndEnrollment).
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
