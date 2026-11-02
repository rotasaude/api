# Descarte do frasco antes do vencimento (ADR 0047, Desvio 8; contrato §3;
# dashboard D7): o responsável da sala (`room_lead`, conferido pelo
# controlador) fecha o frasco com um motivo de 10 a 500 caracteres (cifrado) e
# a sobra de doses vira perda técnica. Um frasco fecha uma vez (trigger):
# já fechado, por descarte ou pelo vencimento → `already_closed`. O frasco é
# travado (FOR UPDATE) antes de ler as doses usadas. Evento
# `vaccination.vial_closed` só com ids; o motivo nunca sai em evento nem log.
module Vaccination
  module CloseOutVial
    module_function

    # -> Result.ok(vial:) | fail(:invalid_reason, details: { path: "reason" }) | fail(:already_closed)
    def call(vial:, reason:, by:, now: Time.current)
      clean = reason.is_a?(String) ? reason.strip : nil
      return Result.fail(:invalid_reason, details: { path: "reason" }) unless clean && Catalog::REASON.cover?(clean.length)

      result = nil
      VialOpening.transaction(requires_new: true) do
        locked = VialOpening.lock("FOR UPDATE").find(vial.id)
        result = if locked.closed_at
          Result.fail(:already_closed)
        else
          locked.update!(closed_at: now, closed_by_user: by, close_reason: clean, technical_loss_doses: locked.doses_left)
          DomainEvents.publish("vaccination.vial_closed", vial_opening_id: locked.id, vaccine_room_id: locked.vaccine_room_id,
                                                          user_id: by.id, cause: "closed_out")
          Result.ok(vial: locked)
        end
      end
      result
    end
  end
end
