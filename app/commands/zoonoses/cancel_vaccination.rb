# Anulação da dose antirrábica (módulo 35b, ADR 0054; contrato §1, §3; plano,
# Desvio 4). Quem registrou ou a coordenação (senão missing_role); `reason`
# 10–500 depois do strip (senão invalid_request path reason; longo é
# recusado, nunca cortado). Trava a dose FOR UPDATE e relê: já anulada → 409
# invalid_transition path status. Grava cancelled_at e cancel_reason (cifrado)
# e estorna a baixa (Zoonoses::ApplyStock.reverse!: o "uma vez" do estorno
# depende desta trava, ver o cabeçalho dele); a falta aberta da dose é
# conciliada pelo sistema. `rabies_vaccination.cancelled` só com o id.
module Zoonoses
  module CancelVaccination
    EVENT = "rabies_vaccination.cancelled".freeze

    module_function

    # -> Result.ok(vaccination:) | fail(:missing_role) | fail(:invalid_request, details: { path: "reason" })
    #    | fail(:invalid_transition, details: { path: "status" })
    def call(vaccination:, reason:, by:)
      return Result.fail(:missing_role) unless vaccination.recorded_by_user_id == by&.id || Access.coordinator?(by)

      clean = reason.is_a?(String) ? reason.strip : nil
      return Result.fail(:invalid_request, details: { path: "reason" }) unless clean && Catalog::NOTE.cover?(clean.length)

      RabiesVaccination.transaction(requires_new: true) do
        locked = RabiesVaccination.lock.find(vaccination.id)
        next Result.fail(:invalid_transition, details: { path: "status" }) if locked.cancelled?

        now = Time.current
        locked.update!(cancelled_at: now, cancel_reason: clean)
        ApplyStock.reverse!(vaccination: locked, by: by, now: now)
        DomainEvents.publish(EVENT, rabies_vaccination_id: locked.id)
        Result.ok(vaccination: locked)
      end
    end
  end
end
