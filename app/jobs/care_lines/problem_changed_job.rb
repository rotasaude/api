# Consumidor de patient_problem.changed (ADR 0040; spec §4): sugestões e
# encerramento daquele paciente. Roda na transação da cidade: o portão lê
# só a plataforma (Gate.enabled?).
module CareLines
  class ProblemChangedJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(patient_problem_id:, **)
      return unless Gate.enabled?(Current.city)

      patient_id = PatientProblem.where(id: patient_problem_id).pick(:patient_id)
      Suggest.for_patient(patient_id, today: Time.zone.today) if patient_id
    end
  end
end
