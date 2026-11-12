# O pedido de reabertura do cidadão (ADR 0051; contrato §3; §16 Q8, Q10; a
# rota é da Task 15). Chamado com a manifestação do cidadão da sessão
# (a posse é conferida pelo controlador):
# - `reason` em REOPEN_REASON (10..2000, sem as bordas) → 422 path reason;
# - só em estado final (senão 422 invalid_transition) e até
#   REOPEN_WINDOW_DAYS (30) dias depois de `concluded_at`, na data local →
#   422 reopen_window_closed;
# - um por ciclo (Q10, único por manifestação e ciclo): com um pendente → 409
#   reopen_pending; já decidido neste ciclo → 422 reopen_already_requested;
# - grava o pedido `pending` do ciclo e o evento `reopen_requested` (do
#   cidadão, visível; sem texto — o motivo fica só no pedido, cifrado).
# Sob Ombudsman::Lock. Sem aviso e sem evento de domínio.
module Ombudsman
  module RequestReopen
    module_function

    # -> Result.ok(manifestation:, request:) | fail(:invalid_request, details: { path: "reason", problems: })
    #  | fail(:not_found) | fail(:invalid_transition) | fail(:reopen_window_closed) | fail(:reopen_pending)
    #  | fail(:reopen_already_requested)
    def call(manifestation:, reason:, now: Time.current)
      value = Input.text(reason, Catalog::REOPEN_REASON)
      return Input.refuse("reason") unless value

      ApplicationRecord.transaction(requires_new: true) do
        locked = Lock.manifestation!(manifestation.id)
        next Result.fail(:not_found) unless locked
        next Result.fail(:invalid_transition) unless locked.final?
        unless Deadlines.within_window?(locked.concluded_at, Catalog::REOPEN_WINDOW_DAYS, today: now.in_time_zone.to_date)
          next Result.fail(:reopen_window_closed)
        end

        existing = OmbudsmanReopenRequest.where(ombudsman_manifestation_id: locked.id).pluck(:state, :cycle)
        next Result.fail(:reopen_pending) if existing.any? { |state, _| state == "pending" }
        next Result.fail(:reopen_already_requested) if existing.any? { |_, cycle| cycle == locked.cycle }

        request = OmbudsmanReopenRequest.create!(ombudsman_manifestation: locked, cycle: locked.cycle, reason: value, state: "pending",
                                                 created_at: now, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: locked, kind: "reopen_requested", actor: "citizen", text: nil,
                               data: { "cycle" => locked.cycle }, visible_to_citizen: true, created_at: now)
        Result.ok(manifestation: locked, request: request)
      end
    end
  end
end
