# Formas JSON da urgência (contrato §2, §4 e §14 Q6, Q18, Q19), compartilhadas
# pelos controladores de /urgency/*.
module Urgency
  module Json
    # Campos clínicos que saem só para quem tem acesso clínico (§14 Q19).
    CLINICAL_CLASSIFICATION_KEYS = %i[complaint vital_signs pain_scale justification criterion].freeze

    module_function

    # Resposta da chegada: `{ attendance_id, encounter_id, ticket | null, patient: <patient-ref> }`.
    def arrival(encounter:, attendance:, patient:)
      { attendance_id: attendance.id, encounter_id: encounter.id, ticket: attendance.ticket, patient: PatientRef.call(patient) }
    end

    # Detalhe do encontro (§14 Q6): a mesma forma no GET, na classificação, na
    # identificação e no desfecho. `<patient-ref>` com a descrição do
    # provisório; a cor e o estouro pela classificação vigente; as
    # classificações em ordem, cada uma com a sugestão `{ color, criterion }`
    # (o `criterion` do topo só quando a cor final é a sugerida). Sem acesso
    # clínico (`clinical: false`, §14 Q19), sem queixa, sinais, dor,
    # justificativa, critério nem os campos cifrados do desfecho — a descrição
    # fica. Quem renderiza grava a trilha (Urgency::BaseController#render_encounter).
    def encounter(encounter, clinical:, now: Time.current)
      attendance = encounter.attendance
      current = encounter.current_classification
      {
        id: encounter.id, attendance_id: attendance.id, health_unit_id: attendance.health_unit_id, state: encounter.state,
        ticket: attendance.ticket, arrived_at: attendance.checked_in_at.iso8601,
        patient: PatientRef.call(attendance.patient, detail: true),
        color: current&.color, max_wait_minutes: current&.max_wait_minutes, overdue: encounter.overdue?(at: now),
        first_classified_at: encounter.first_classified_at&.iso8601,
        classifications: encounter.classifications.includes(classified_by_user: :professional).map { |c| classification(c, clinical:) },
        consultation_id: encounter.consultation_id, consultation_status: encounter.consultation&.status,
        outcome: encounter.outcome && outcome(encounter.outcome, clinical:)
      }
    end

    def classification(item, clinical:)
      suggested = item.suggested_color && { color: item.suggested_color, criterion: item.criterion }
      json = {
        id: item.id, position: item.position, color: item.color, suggested_color: item.suggested_color, suggested: suggested,
        criterion: item.color == item.suggested_color ? item.criterion : nil, complaint: item.complaint,
        vital_signs: item.vital_signs, pain_scale: item.pain_scale, justification: item.justification,
        max_wait_minutes: item.max_wait_minutes, protocol_definition_id: item.protocol_definition_id,
        classified_at: item.created_at.iso8601,
        by: { name: Screenings::Json.staff_name(item.classified_by_user), cbo_code: item.cbo_code }
      }
      return json if clinical

      json[:suggested] = suggested&.except(:criterion)
      json.except(*CLINICAL_CLASSIFICATION_KEYS)
    end

    def outcome(item, clinical:)
      guidance = item.return_days && { days: item.return_days, reason: item.return_reason }
      json = { kind: item.kind, destination: item.destination, vacancy_request: item.vacancy_request, return_guidance: guidance,
               recorded_at: item.recorded_at.iso8601, by: { name: Screenings::Json.staff_name(item.recorded_by_user) } }
      return json if clinical

      json[:return_guidance] = guidance&.except(:reason)
      json.except(:destination, :vacancy_request)
    end
    private_class_method :classification, :outcome
  end
end
