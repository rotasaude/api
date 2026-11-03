# Decisão da comissão de TFD (contrato §6; §14 T12; plano, Desvios 11–12):
# `authorize` | `return` | `deny`, sempre com motivo (10..500, cifrado na
# linha de tfd_case_events), só de `submitted`. `authorize` repete as regras
# do envio e acrescenta `appointment_required` e `billing_unit_missing`
# (Tfd::Rules, stage :authorize), todas de uma vez em `problems[]`. O
# interruptor do faturamento e os parâmetros são lidos FORA da transação.
# Evento tfd.case_decided só com ids e o código da decisão.
module Tfd
  module DecideCase
    module_function

    # -> Result.ok(tfd_case:) | fail(:missing_role | :invalid_request | :invalid_transition | <regra>, path:, problems:)
    def call(tfd_case:, decision:, reason:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      text = Transport::Support.text(reason, Catalog::REASON)
      paths = []
      paths << "decision" unless Catalog::DECISIONS.key?(decision)
      paths << "reason" unless text
      return Transport::Support.refuse(paths) if paths.any?

      settings = Transport::Settings.current
      billing = Billing::Gate.enabled?(Current.city)
      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless tfd_case.status == "submitted"

        if decision == "authorize"
          problems = Rules.problems(tfd_case, settings: settings, stage: :authorize, billing_enabled: billing)
          next Transport::Support.failure(problems) if problems.any?
        end

        moved = Transition.call(tfd_case: tfd_case, to: Catalog::DECISIONS.fetch(decision), by: by, reason: text)
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_decided", tfd_case_id: tfd_case.id, user_id: by.id, decision: decision)
        moved
      end
    end
  end
end
