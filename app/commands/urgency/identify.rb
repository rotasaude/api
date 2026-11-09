# Identificação do paciente provisório da UPA, uma vez só (ADR 0050, R4;
# contrato §4 e §14 Q5, Q15, Q17, Q21, Q23; plano, Desvios 5–7).
#
# Duas formas, exatamente uma:
# - `patient_id` (paciente real existente, identificado e não fundido) → a
#   fusão (Urgency::Merge): os registros do encontro mudam de dono, o
#   provisório recebe merged_into_id e nada é apagado;
# - `new_patient` (a forma do 24a, com a conferência de duplicado do Q23) → o
#   provisório recebe os dados e `unidentified = false`, sem fusão. CPF ou CNS
#   que já existem → cpf_taken/cns_taken, nunca fusão silenciosa pelo que foi
#   digitado. A descrição do não identificado fica (é ela que marca que o
#   paciente foi provisório).
#
# Recusas: forma → invalid_request (`patient`, `patient_id`, `new_patient.*`,
# `duplicates_reviewed`); encontro de paciente que nunca foi provisório →
# not_unidentified; provisório já identificado (fundido, ou identificado por
# dados novos) ou encontro cuja fusão já levou o atendimento ao real →
# already_identified; patient_id inexistente → patient_not_found; alvo
# provisório ou fundido → invalid_request `patient_id`; linha do provisório
# numa tabela bloqueante → merge_blocked. Qualquer recusa desfaz tudo.
#
# Travas na ordem da chegada (Urgency::Arrive): a unidade (FOR SHARE) e
# depois os pacientes, por id crescente (FOR UPDATE). A trava do provisório
# serializa duas identificações simultâneas: a segunda relê o provisório já
# fundido e recebe already_identified (Review Focus 1). O encontro fechado
# também se identifica (o óbito do não identificado, Review Focus 5).
#
# Evento `urgency.patient_identified` só com ids e contagens: encounter_id,
# patient_id e, na fusão, merged_from_id, moved e kept_duplicates.
module Urgency
  module Identify
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    EVENT = "urgency.patient_identified".freeze

    module_function

    # -> Result.ok(patient:, merged_from_id:, moved: { table => n }, kept_duplicates: { table => n }) | Result.fail(reason, details:)
    def call(encounter:, by:, patient_id: nil, new_patient: nil, duplicates_reviewed: nil)
      form = parse_form(patient_id, new_patient, duplicates_reviewed)
      return form if form.failure?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = identify(encounter, form.payload, by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def parse_form(patient_id, new_patient, duplicates_reviewed)
      given = { patient_id: patient_id, new_patient: new_patient }.compact
      return refuse(:invalid_request, "patient") unless given.size == 1
      return NewPatient.parse(new_patient, duplicates_reviewed) if new_patient
      return refuse(:invalid_request, "patient_id") unless patient_id.is_a?(String) && patient_id.match?(UUID)

      Result.ok(patient_id: patient_id)
    end

    def identify(encounter, form, by)
      attendance = Attendance.find(encounter.attendance_id)
      HealthUnit.lock("FOR SHARE").find(attendance.health_unit_id)
      locked = Patient.where(id: [ attendance.patient_id, form[:patient_id] ].compact).order(:id).lock.index_by(&:id)
      # Relido depois da trava: quem esperou vê o atendimento e o provisório como a outra identificação deixou.
      patient = locked[attendance.reload.patient_id] || Patient.lock.find(attendance.patient_id)
      state = provisional_state(encounter, patient)
      return state if state.failure?

      if form[:patient_id]
        merge(encounter, patient, locked[form[:patient_id]])
      else
        assign(encounter, patient, form, by)
      end
    end

    # O paciente do atendimento ainda é o provisório por identificar?
    def provisional_state(encounter, patient)
      return Result.ok if patient.unidentified && !patient.merged?
      return Result.fail(:already_identified) if patient.merged? || patient.unidentified_description.present?
      # A fusão leva o atendimento ao real: o encontro que ela já identificou
      # aparece com um paciente que nunca foi provisório.
      return Result.fail(:already_identified) if identified_before?(encounter)

      Result.fail(:not_unidentified)
    end

    def identified_before?(encounter)
      DomainEvent.where(name: EVENT).where("payload->>'encounter_id' = ?", encounter.id).exists?
    end

    def merge(encounter, provisional, target)
      return refuse(:patient_not_found, "patient_id") unless target
      return refuse(:invalid_request, "patient_id") if target.id == provisional.id || target.unidentified || target.merged?

      merged = Merge.call(provisional: provisional, into: target)
      return merged if merged.failure?

      moved, kept = merged.payload.values_at(:moved, :kept_duplicates)
      DomainEvents.publish(EVENT, encounter_id: encounter.id, patient_id: target.id, merged_from_id: provisional.id,
                                  moved: moved.values.sum, kept_duplicates: kept.values.sum)
      Result.ok(patient: target, merged_from_id: provisional.id, moved: moved, kept_duplicates: kept)
    end

    def assign(encounter, provisional, form, by)
      assigned = NewPatient.assign(patient: provisional, new_patient: form[:new_patient], reviewed: form[:reviewed], by: by)
      return assigned if assigned.failure?

      DomainEvents.publish(EVENT, encounter_id: encounter.id, patient_id: provisional.id)
      Result.ok(patient: provisional.reload, merged_from_id: nil, moved: {}, kept_duplicates: {})
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :parse_form, :identify, :provisional_state, :identified_before?, :merge, :assign, :refuse
  end
end
