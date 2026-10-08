# app/services/patients/problem_replay.rb
# "Quem disse que ele é diabético, e quando" (ADR 0031): o estado do problema
# reconstruído dos eventos, e o histórico com profissional e origem.
module Patients
  module ProblemReplay
    module_function

    def state(problem)
      last = problem.events.order(:created_at, :id).last
      last && { status: last.status_after, onset_on: last.onset_on, onset_precision: last.onset_precision,
                resolved_on: last.resolved_on }
    end

    def history(problem)
      problem.events.order(:created_at, :id).map do |event|
        { kind: event.kind, user_id: event.user_id, consultation_id: event.consultation_id,
          addendum_id: event.addendum_id, created_at: event.created_at }
      end
    end
  end
end
