# app/commands/patients/apply_problem_event.rb
# Único caminho de escrita da lista de problemas (ADR 0031; spec §3). Grava o
# evento ANTES de mudar o estado — o trigger patient_problems_guard exige um
# evento da mesma transação com os mesmos valores. Quem chama abriu a
# transação e travou o paciente (Finalize, AddAddendum).
#   evaluate      — avaliado sem mudança (sem evento)
#   add           — ativo igual: avaliar; resolvido igual: reativar; senão incluir
#   resolve       — ativo → resolvido em `on`
#   correct_onset — corrige início e precisão
module Patients
  module ApplyProblemEvent
    ACTIONS = %w[evaluate add resolve correct_onset].freeze

    module_function

    def call(patient:, action:, by:, source:, terminology: nil, code: nil, release_id: nil, problem: nil,
             onset_on: nil, onset_precision: nil, on: Time.zone.today)
      consultation, addendum = source.values_at(:consultation, :addendum)
      raise ArgumentError, "source: consulta OU adendo" unless consultation.nil? ^ addendum.nil?
      return Result.fail(:invalid_problem) unless ACTIONS.include?(action.to_s)
      return Result.fail(:invalid_problem) if problem && problem.patient_id != patient.id

      origin = { by: by, consultation: consultation, addendum: addendum }
      case action.to_s
      when "evaluate"
        problem ? Result.ok(problem: problem, event: nil) : Result.fail(:invalid_problem)
      when "add"
        add(patient, terminology, code, release_id, onset_on, onset_precision, origin)
      when "resolve"
        return Result.fail(:invalid_problem) unless problem&.active?

        write(problem.lock!, "resolved", { status: "resolved", resolved_on: on }, origin)
      when "correct_onset"
        return Result.fail(:invalid_problem) unless problem

        write(problem.lock!, "onset_corrected", { onset_on: onset_on, onset_precision: onset_precision }, origin)
      end
    end

    def add(patient, terminology, code, release_id, onset_on, onset_precision, origin)
      scope = PatientProblem.where(patient_id: patient.id, terminology: terminology, code: code)
      active = scope.where(status: "active").lock.first
      return Result.ok(problem: active, event: nil) if active

      resolved = scope.where(status: "resolved").order(updated_at: :desc, id: :desc).lock.first
      if resolved
        attrs = { status: "active", resolved_on: nil, terminology_release_id: release_id }
        attrs.merge!(onset_on: onset_on, onset_precision: onset_precision) if onset_on
        return write(resolved, "reactivated", attrs, origin)
      end

      problem = PatientProblem.new(id: SecureRandom.uuid, patient: patient, terminology: terminology, code: code,
                                   terminology_release_id: release_id, status: "active",
                                   onset_on: onset_on, onset_precision: onset_precision)
      write(problem, "added", {}, origin)
    end

    def write(problem, kind, attrs, origin)
      problem.assign_attributes(attrs)
      event = PatientProblemEvent.create!(
        patient_problem_id: problem.id, kind: kind, consultation_id: origin[:consultation]&.id,
        addendum_id: origin[:addendum]&.id, user: origin[:by], status_after: problem.status,
        onset_on: problem.onset_on, onset_precision: problem.onset_precision, resolved_on: problem.resolved_on,
        terminology_release_id: problem.terminology_release_id
      )
      problem.save!
      link = origin[:consultation] ? { consultation_id: origin[:consultation].id } : { addendum_id: origin[:addendum].id }
      DomainEvents.publish("patient_problem.changed", patient_problem_id: problem.id, kind: kind, **link)
      Result.ok(problem: problem, event: event)
    end
    private_class_method :add, :write
  end
end
