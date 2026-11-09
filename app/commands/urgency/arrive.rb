# Chegada na UPA pela recepção (ADR 0050; contrato §4, §14 Q4, Q15; plano,
# Desvios 2–4 e 12). Na mesma transação: o Patient (novo pelo 24a, com a
# conferência de duplicado do Q23 — Urgency::NewPatient —, ou o provisório,
# sem ela), o atendimento `walk_in` (waiting, check_in_method
# urgency_reception, citizen_id nulo, senha só com a sala de espera) e o
# encontro (waiting_classification).
#
# Recusas, nesta ordem: unidade inativa ou inexistente → invalid_unit; CAPS →
# caps_unit_not_allowed (P32 do 31) antes de não UPA → not_an_upa; zero ou
# mais de uma forma (patient_id | new_patient | unidentified) → invalid_request
# `path: "patient"`; forma malformada ou chave desconhecida dentro de
# `new_patient`/`unidentified` → invalid_request com o path; patient_id malformado, de provisório ou de fundido →
# invalid_request `path: "patient_id"`, inexistente → patient_not_found; o
# paciente novo com duplicado suspeito (sem `duplicates_reviewed: true`) →
# duplicate_suspected com os candidate_ids; o mesmo paciente com encontro
# aberto na UPA → encounter_open (o índice idx_attendances_open_walk_in é a
# última palavra). Qualquer recusa desfaz tudo.
#
# `waiting_room` é o waiting_room_display já lido pelo chamador, FORA da
# transação. Nada da pessoa (nome, CPF, CNS, descrição) em evento, log ou
# Result.details: só o path do campo.
module Urgency
  module Arrive
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    OPEN_WALK_IN_INDEX = "idx_attendances_open_walk_in".freeze
    UNIDENTIFIED_KEYS = %w[description].freeze

    module_function

    # -> Result.ok(encounter:, attendance:, patient:) | Result.fail(reason, details: { path: }?)
    def call(health_unit_id:, by:, waiting_room:, patient_id: nil, new_patient: nil, unidentified: nil,
             duplicates_reviewed: nil, now: Time.current)
      unit = uuid?(health_unit_id) ? HealthUnit.active_units.find_by(id: health_unit_id) : nil
      return refuse(:invalid_unit, "health_unit_id") unless unit
      return Result.fail(:caps_unit_not_allowed) if unit.caps?
      return Result.fail(:not_an_upa) unless unit.upa?

      form = parse_form(patient_id, new_patient, unidentified, duplicates_reviewed)
      return form if form.failure?

      result = nil
      # requires_new: dentro de uma transação de fora, a recusa desfaz também
      # este trecho (savepoint), e nada do paciente, atendimento ou encontro fica.
      ApplicationRecord.transaction(requires_new: true) do
        unit = HealthUnit.lock_active!(unit.id)
        person = patient_for(form.payload, by)
        if person.failure?
          result = person
          raise ActiveRecord::Rollback
        end

        patient = person.payload.fetch(:patient)
        if open_encounter?(patient, unit)
          result = Result.fail(:encounter_open)
          raise ActiveRecord::Rollback
        end

        attendance = Attendance.create!(origin_kind: "walk_in", check_in_method: "urgency_reception", patient: patient,
                                        health_unit: unit, checked_in_by_user: by, checked_in_at: now,
                                        **Attendances::CheckIn.ticket_for(unit, at: now, waiting_room: waiting_room))
        encounter = UrgencyEncounter.create!(attendance: attendance)
        Attendances::CheckIn.publish(attendance)
        DomainEvents.publish("urgency.arrived", encounter_id: encounter.id)
        result = Result.ok(encounter: encounter, attendance: attendance, patient: patient)
      end
      result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless Attendances::CheckIn.constraint_name(e) == OPEN_WALK_IN_INDEX

      Result.fail(:encounter_open)
    rescue HealthUnit::Inactive
      refuse(:invalid_unit, "health_unit_id")
    end

    # Exatamente uma das três formas, e a forma de cada uma (sem banco).
    def parse_form(patient_id, new_patient, unidentified, duplicates_reviewed)
      given = { patient_id: patient_id, new_patient: new_patient, unidentified: unidentified }.compact
      return refuse(:invalid_request, "patient") unless given.size == 1

      case given.keys.first
      when :patient_id
        uuid?(patient_id) ? Result.ok(patient_id: patient_id) : refuse(:invalid_request, "patient_id")
      when :new_patient
        NewPatient.parse(new_patient, duplicates_reviewed)
      else
        return refuse(:invalid_request, "unidentified") unless unidentified.is_a?(Hash)

        unknown = (unidentified.keys.map(&:to_s) - UNIDENTIFIED_KEYS).first
        return refuse(:invalid_request, "unidentified.#{unknown}"[0, NewPatient::KEY_PATH_MAX]) if unknown

        description = unidentified.stringify_keys["description"]
        description = description.strip if description.is_a?(String)
        valid = description.is_a?(String) && Catalog::DESCRIPTION.cover?(description.length)
        valid ? Result.ok(description: description) : refuse(:invalid_request, "unidentified.description")
      end
    end

    # Dentro da transação: o existente sob Patient.lock (nunca provisório nem
    # fundido), o novo pelo Urgency::NewPatient (CreateReviewed, savepoint e
    # trava da match_key) ou o provisório.
    def patient_for(form, by)
      if form[:patient_id]
        patient = Patient.lock.find_by(id: form[:patient_id])
        return refuse(:patient_not_found, "patient_id") unless patient
        return refuse(:invalid_request, "patient_id") if patient.unidentified || patient.merged?

        Result.ok(patient: patient)
      elsif form[:new_patient]
        NewPatient.create(new_patient: form[:new_patient], reviewed: form[:reviewed], by: by)
      else
        patient = Patient.create!(no_cpf_reason: Catalog::UNIDENTIFIED_REASON, unidentified: true,
                                  unidentified_description: form[:description])
        DomainEvents.publish("patient.created", patient_id: patient.id, user_id: by.id)
        Result.ok(patient: patient)
      end
    end

    def open_encounter?(patient, unit)
      Attendance.open_attendances.where(origin_kind: "walk_in", patient_id: patient.id, health_unit_id: unit.id).exists?
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse_form, :patient_for, :open_encounter?, :refuse, :uuid?
  end
end
