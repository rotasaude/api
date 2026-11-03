# Cancelamento do processo de TFD (§14 T8, T25; plano, Desvio 12): só a
# comissão (o step-up é da rota), com motivo 10..500 (cifrado no andamento),
# de qualquer situação não terminal MENOS o rascunho — recusado aqui com
# invalid_transition antes de chegar ao CHECK ck_tfd_cases_submitted (o
# rascunho abandonado fica `draft`). Evento tfd.case_cancelled só com ids.
module Tfd
  module CancelCase
    CANCELLABLE = %w[submitted returned authorized scheduled travelling].freeze

    module_function

    # -> Result.ok(tfd_case:) | fail(:missing_role | :invalid_request | :invalid_transition, path:, problems:)
    def call(tfd_case:, reason:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      text = Transport::Support.text(reason, Catalog::REASON)
      return Transport::Support.refuse([ "reason" ]) unless text

      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless CANCELLABLE.include?(tfd_case.status)

        moved = Transition.call(tfd_case: tfd_case, to: "cancelled", by: by, reason: text)
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_cancelled", tfd_case_id: tfd_case.id, user_id: by.id)
        moved
      end
    end
  end
end
