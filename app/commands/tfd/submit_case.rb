# Envio do laudo à comissão (contrato §6; plano, Desvios 11–12): só o autor,
# só `draft` ou `returned`. As regras do Tfd::Rules (stage :submit) recusam
# todas de uma vez em `problems[]`; passando, Tfd::Transition → `submitted` e
# o evento tfd.case_submitted (só ids). Os parâmetros da cidade são lidos
# antes da trava.
module Tfd
  module SubmitCase
    EDITABLE = %w[draft returned].freeze

    module_function

    # Processo de outro autor → not_found (como o read).
    # -> Result.ok(tfd_case:) | fail(:not_found | :invalid_transition | <regra>, path:, problems:)
    def call(tfd_case:, by:)
      settings = Transport::Settings.current
      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:not_found) unless by && tfd_case.requester_user_id == by.id
        next Result.fail(:invalid_transition) unless EDITABLE.include?(tfd_case.status)

        problems = Rules.problems(tfd_case, settings: settings, stage: :submit)
        next Transport::Support.failure(problems) if problems.any?

        moved = Transition.call(tfd_case: tfd_case, to: "submitted", by: by)
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_submitted", tfd_case_id: tfd_case.id, user_id: by.id)
        moved
      end
    end
  end
end
