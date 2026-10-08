# app/commands/consultations/finalize.rb
# Finalizar a consulta (ADR 0031; spec §4): requisitos do registro, e numa
# transação só (savepoint — falha não deixa nada): eventos de problema
# (Patients::ApplyProblemEvent), itens só de acréscimo, finalized, e o
# fechamento do atendimento pelo comando existente (retorno/encaminhamento
# geram o pedido). A consulta vira finalized ANTES do Close: o Close recusa
# rascunho aberto. Ordem de travas: atendimento → consulta → paciente.
module Consultations
  class Finalize
    OUTCOME_KEYS = %w[outcome referral_unit_id referral_note].freeze

    def self.call(consultation:, outcome_params:, by:)
      outcome = normalize(outcome_params)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        attendance = Attendance.lock.find(consultation.attendance_id)
        consultation.lock!
        next result = Result.fail(:not_author) unless consultation.author_user_id == by.id
        next result = Result.fail(:not_draft) unless consultation.draft?

        patient = Patient.lock.find(consultation.patient_id)
        ready = requirements(consultation, patient)
        next result = ready if ready.failure?

        failure = materialize!(consultation, patient, by)
        if failure
          result = failure
          raise ActiveRecord::Rollback
        end
        consultation.update!(status: "finalized", finalized_at: Time.current, draft_items: {})
        closed = Attendances::Close.call(attendance: attendance, outcome: outcome["outcome"],
                                         referral_unit_id: outcome["referral_unit_id"],
                                         referral_note: outcome["referral_note"], by: by)
        if closed.failure?
          result = closed
          raise ActiveRecord::Rollback
        end
        DomainEvents.publish("consultation.finalized", consultation_id: consultation.id, attendance_id: attendance.id)
        result = Result.ok(consultation: consultation, attendance: closed.payload[:attendance],
                           appointment_request: closed.payload[:appointment_request])
      end
      consultation.reload if result.failure?
      result
    end

    def self.requirements(consultation, patient)
      items = consultation.draft_items
      return Result.fail(:no_problem_evaluated) if Array(items["evaluated_problems"]).empty?
      return Result.fail(:no_conduct) if Array(items["conducts"]).empty?
      return Result.fail(:assessment_or_plan_required) if consultation.assessment.blank? && consultation.plan.blank?
      return Result.fail(:patient_name_missing) if patient.full_name.blank?
      return Result.fail(:invalid_care_type) unless Ledi::ConsultationMapping.care_type?(consultation.care_type)

      physician = Ledi::ConsultationMapping.cid10_allowed?(consultation.cbo_code)
      # Como no ItemsInput: não médico avalia/resolve CID-10 já na lista; só
      # não registra CID-10 novo (add) nem justificativa de exame.
      Array(items["evaluated_problems"]).each_with_index do |item, index|
        if item["action"] == "add" && item["terminology"] == "cid10" && !physician
          return Result.fail(:cid10_not_allowed_for_cbo, details: { index: index })
        end
      end
      Array(items["exam_requests"]).each_with_index do |exam, index|
        if exam["cid10_justification"] && !physician
          return Result.fail(:cid10_not_allowed_for_cbo, details: { index: index })
        end
      end
      # Decisão do usuário 2026-10-08: a ficha de não médico omite os problemas
      # CID-10, e o layout exige ao menos um problemasCondicoes
      # (dicionario-fai.html #28, mínimo 1) — sem CIAP-2 avaliado ela sairia vazia.
      if !physician && Array(items["evaluated_problems"]).none? { |item| item["terminology"] == "ciap2" }
        return Result.fail(:ciap2_required_for_cbo)
      end
      Result.ok
    end

    # Devolve nil, ou o Result de falha (com o índice do problema).
    def self.materialize!(consultation, patient, by)
      today = Time.zone.today
      items = consultation.draft_items
      Array(items["evaluated_problems"]).each_with_index do |item, index|
        applied = Patients::ApplyProblemEvent.call(
          patient: patient, action: item["action"], by: by, source: { consultation: consultation },
          terminology: item["terminology"], code: item["code"], release_id: item["release_id"],
          problem: item["problem_id"] && PatientProblem.find_by(id: item["problem_id"]),
          onset_on: item["onset_on"] && Date.iso8601(item["onset_on"]), onset_precision: item["onset_precision"], on: today
        )
        return Result.fail(applied.reason, details: { index: index }) if applied.failure?

        record_problem!(consultation, applied.payload[:problem], item["action"])
      end
      Array(items["conducts"]).each { |code| ConsultationConduct.create!(consultation: consultation, code: code, action: "add") }
      Array(items["exam_requests"]).each do |exam|
        ConsultationExamRequest.create!(consultation: consultation, sigtap_code: exam["sigtap_code"],
                                        sigtap_competence: exam["sigtap_competence"],
                                        cid10_justification: exam["cid10_justification"], status: "requested")
      end
      nil
    end

    def self.record_problem!(consultation, problem, action, addendum: nil)
      ConsultationProblem.create!(consultation: consultation, addendum: addendum, patient_problem: problem, action: action,
                                  terminology: problem.terminology, code: problem.code,
                                  terminology_release_id: problem.terminology_release_id, status_after: problem.status,
                                  onset_on: problem.onset_on, onset_precision: problem.onset_precision,
                                  resolved_on: problem.resolved_on)
    end

    def self.normalize(params)
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      params.is_a?(Hash) ? params.deep_stringify_keys.slice(*OUTCOME_KEYS) : {}
    end
    private_class_method :requirements, :materialize!, :normalize
  end
end
