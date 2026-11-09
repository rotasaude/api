# Pareamento da TV (ADR 0050; contrato §8 e §14 Q8; Valor fixado 6;
# preflight C-17): troca o código de 6 dígitos (vivo, de TV ativa) por um
# token longo (`SecureRandom.urlsafe_base64(48)`, 64 caracteres) que vale até
# a revogação; só o SHA-256 dele fica no banco e o token em claro só sai nesta
# resposta. O código é zerado (uso único), `revoked_at` também, e `paired_at`
# é gravado. TV com token vivo: o antigo é revogado antes (display_revoked;
# o digest dele vai para `revoked_token_digest`, e a TV antiga recebe
# display_revoked) e só depois sai o display_paired. Código desconhecido, expirado, já usado ou
# de TV desativada → invalid_pairing_code, sem dizer qual.
module WaitingRoom
  module Pair
    CODE = /\A\d{6}\z/

    module_function

    # -> Result.ok(display:, display_token:) | fail(:invalid_pairing_code)
    def call(code:, now: Time.current)
      return Result.fail(:invalid_pairing_code) unless code.is_a?(String) && code.match?(CODE)

      WaitingRoomDisplay.transaction(requires_new: true) do
        display = WaitingRoomDisplay.lock.find_by(pairing_code_digest: WaitingRoomDisplay.digest(code))
        next Result.fail(:invalid_pairing_code) unless display&.active && display.pairing_expires_at > now

        Revoke.revoke!(display, at: now)
        token = SecureRandom.urlsafe_base64(48)
        display.update!(token_digest: WaitingRoomDisplay.digest(token), pairing_code_digest: nil, pairing_expires_at: nil,
                        revoked_at: nil, paired_at: now)
        DomainEvents.publish(
          "waiting_room.display_paired",
          display_id: display.id
        )
        Result.ok(display: display, display_token: token)
      end
    end
  end
end
