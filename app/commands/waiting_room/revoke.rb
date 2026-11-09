# Revoga a TV (ADR 0050; contrato §8 e §14 Q8; preflight C-17): o token vivo
# deixa de valer (o painel responde 401 display_revoked) e o código pendente
# é descartado. O digest vivo vai para `revoked_token_digest` (substitui o
# anterior), para a TV antiga saber que foi revogada e pedir um novo código.
# Sem token vivo, só descarta o código, sem evento. Evento waiting_room.display_revoked
# só com o display_id. A TV volta a funcionar só pareada de novo.
module WaitingRoom
  module Revoke
    module_function

    # `by` é o administrador da rota (a autorização é do controller); o evento
    # leva só o id da TV (contrato §12). -> Result.ok(display:)
    def call(display:, by:)
      raise ArgumentError, "by é obrigatório" unless by

      WaitingRoomDisplay.transaction(requires_new: true) do
        locked = WaitingRoomDisplay.lock.find(display.id)
        revoke!(locked)
        locked.save! if locked.changed?
        Result.ok(display: locked)
      end
    end

    # Com a linha já travada pelo chamador (SaveDisplay, Pair): marca a
    # revogação e publica, sem gravar. -> true se havia token vivo.
    def revoke!(display, at: Time.current)
      live = display.paired?
      display.assign_attributes(pairing_code_digest: nil, pairing_expires_at: nil)
      return false unless live

      display.assign_attributes(revoked_token_digest: display.token_digest, token_digest: nil, revoked_at: at)
      DomainEvents.publish(
        "waiting_room.display_revoked",
        display_id: display.id
      )
      true
    end
  end
end
