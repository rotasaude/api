# Cancelamento do processo de TFD (§14 T8, T25; plano, Desvio 12): só a
# comissão (o step-up é da rota), com motivo 10..500 (cifrado no andamento).
# Quais situações cancelam é do Tfd::Transition (não terminais, sem o
# rascunho: invalid_transition antes de qualquer gravação, longe do CHECK
# ck_tfd_cases_submitted; a rota já dá 404 ao rascunho). Evento
# tfd.case_cancelled só com ids.
module Tfd
  module CancelCase
    module_function

    # -> Result.ok(tfd_case:) | fail(:missing_role | :invalid_request | :invalid_transition, path:, problems:)
    def call(tfd_case:, reason:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      text = Transport::Support.text(reason, Catalog::REASON)
      return Transport::Support.refuse([ "reason" ]) unless text

      TfdCase.transaction(requires_new: true) do
        moved = Transition.call(tfd_case: tfd_case, to: "cancelled", by: by, reason: text)
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_cancelled", tfd_case_id: tfd_case.id, user_id: by.id)
        moved
      end
    end
  end
end
