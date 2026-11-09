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
#   digitado. A descrição do não identificado fica.
#
# O encontro sabe com que provisório nasceu (`provisional_patient_id`, gravado
# pela chegada e imutável): sem ele, o paciente nunca foi provisório →
# not_unidentified; com ele já fundido ou já identificado → already_identified.
#
# Recusas: forma → invalid_request (`patient`, `patient_id`, `new_patient.*`,
# `duplicates_reviewed`); patient_id inexistente → patient_not_found; alvo
# provisório ou fundido → invalid_request `patient_id`; encontro ainda aberto
# e o alvo com walk_in aberto na mesma unidade → encounter_open (a fusão
# dividiria o encontro entre os dois); linha do provisório numa tabela
# bloqueante → merge_blocked. Qualquer recusa desfaz tudo.
#
# Travas: a unidade (FOR SHARE, como a chegada), o atendimento (FOR UPDATE,
# antes dos pacientes — a ordem do Consultations::Finalize: atendimento →
# consulta → paciente) e os pacientes por id crescente (FOR UPDATE). A trava
# do atendimento e a do provisório serializam duas identificações
# simultâneas: a segunda relê o provisório já fundido e recebe
# already_identified (Review Focus 1). O encontro fechado também se
# identifica (o óbito do não identificado, Review Focus 5).
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
        result = identify(UrgencyEncounter.find(encounter.id), form.payload, by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def parse_form(patient_id, new_patient, duplicates_reviewed)
      given = { patient_id: patient_id, new_patient: new_patient }.compact
      return refuse(:invalid_request, "patient") unless given.size == 1
      return NewPatient.parse(new_patient, duplicates_reviewed) if new_patient
      return refuse(:invalid_request, "patient_id") unless patient_id.is_a?(String) && patient_id.match?(UUID)

      # O uuid do Postgres sai em minúsculas: a chave do index_by também.
      Result.ok(patient_id: patient_id.downcase)
    end

    def identify(encounter, form, by)
      return Result.fail(:not_unidentified) unless encounter.provisional_patient_id

      HealthUnit.lock("FOR SHARE").find(encounter.attendance.health_unit_id)
      attendance = Attendance.lock.find(encounter.attendance_id)
      locked = Patient.where(id: [ encounter.provisional_patient_id, form[:patient_id] ].compact).order(:id).lock.index_by(&:id)
      provisional = locked.fetch(encounter.provisional_patient_id)
      return Result.fail(:already_identified) if provisional.merged? || !provisional.unidentified

      if form[:patient_id]
        merge(encounter, attendance, provisional, locked[form[:patient_id]])
      else
        assign(encounter, provisional, form, by)
      end
    end

    def merge(encounter, attendance, provisional, target)
      return refuse(:patient_not_found, "patient_id") unless target
      return refuse(:invalid_request, "patient_id") if target.id == provisional.id || target.unidentified || target.merged?
      return Result.fail(:encounter_open) if splits_open_encounter?(attendance, target)

      merged = Merge.call(provisional: provisional, into: target)
      return merged if merged.failure?

      moved, kept = merged.payload.values_at(:moved, :kept_duplicates)
      DomainEvents.publish(EVENT, encounter_id: encounter.id, patient_id: target.id, merged_from_id: provisional.id,
                                  moved: moved.values.sum, kept_duplicates: kept.values.sum)
      Result.ok(patient: target, merged_from_id: provisional.id, moved: moved, kept_duplicates: kept)
    end

    # O atendimento do encontro ainda aberto bateria no walk_in aberto do alvo
    # na mesma unidade (idx_attendances_open_walk_in): ficaria com o
    # provisório e o resto iria ao real. Recusa em vez de dividir; fechado um
    # dos dois, a fusão passa. A trava do alvo segura a chegada dele (Arrive).
    def splits_open_encounter?(attendance, target)
      attendance.status != "closed" &&
        Attendance.open_attendances.where(origin_kind: "walk_in", patient_id: target.id, health_unit_id: attendance.health_unit_id).exists?
    end

    def assign(encounter, provisional, form, by)
      assigned = NewPatient.assign(patient: provisional, new_patient: form[:new_patient], reviewed: form[:reviewed], by: by)
      return assigned if assigned.failure?

      DomainEvents.publish(EVENT, encounter_id: encounter.id, patient_id: provisional.id)
      Result.ok(patient: provisional.reload, merged_from_id: nil, moved: {}, kept_duplicates: {})
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :parse_form, :identify, :merge, :splits_open_encounter?, :assign, :refuse
  end
end
