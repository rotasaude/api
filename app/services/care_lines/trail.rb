# Trilha da leitura nominal das linhas de cuidado (ADR 0040; spec §7;
# plano, Desvio 10; contrato §11 L7): o mesmo clinical_record.viewed do 19a,
# access care_line, uma por pessoa mostrada. Só ids.
module CareLines
  module Trail
    module_function

    def viewed!(user:, patient_id:, citizen_id:, enrollment_id: nil, suggestion_id: nil)
      payload = { patient_id: patient_id, user_id: user.id, access: "care_line", reason_code: nil,
                  person_ref: patient_id ? "patient:#{patient_id}" : "citizen:#{citizen_id}" }
      payload[:care_line_enrollment_id] = enrollment_id if enrollment_id
      payload[:care_line_suggestion_id] = suggestion_id if suggestion_id
      DomainEvents.publish("clinical_record.viewed", **payload)
    end
  end
end
