# Código de pareamento da TV (ADR 0050; contrato §8; Valor fixado 6): 6
# dígitos sorteados, só o SHA-256 no banco, vale 10 min e uma vez. O código
# em claro só sai nesta resposta. Um código novo substitui o pendente da
# mesma TV; o token vivo continua valendo até o pareamento (WaitingRoom::Pair
# o revoga antes de trocar). TV desativada → display_inactive.
#
# idx_waiting_room_displays_pairing_code é único entre os códigos guardados:
# um expirado de outra TV com o mesmo digest é zerado antes de gravar, e um
# vivo (ou a corrida de duas emissões) leva RecordNotUnique e um novo sorteio.
module WaitingRoom
  module IssuePairingCode
    TTL = 10.minutes
    ATTEMPTS = 5

    module_function

    # `by` é o administrador da rota (a autorização é do controller).
    # -> Result.ok(code:, expires_at:) | fail(:display_inactive)
    def call(display:, by:, now: Time.current)
      raise ArgumentError, "by é obrigatório" unless by

      attempts = 0
      begin
        attempts += 1
        issue(display, now)
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < ATTEMPTS
        raise
      end
    end

    def issue(display, now)
      code = format("%06d", SecureRandom.random_number(10**6))
      digest = WaitingRoomDisplay.digest(code)
      WaitingRoomDisplay.transaction(requires_new: true) do
        locked = WaitingRoomDisplay.lock.find(display.id)
        next Result.fail(:display_inactive) unless locked.active

        WaitingRoomDisplay.where(pairing_code_digest: digest).where(pairing_expires_at: ..now).where.not(id: locked.id)
                          .update_all(pairing_code_digest: nil, pairing_expires_at: nil)
        locked.update!(pairing_code_digest: digest, pairing_expires_at: now + TTL)
        Result.ok(code: code, expires_at: locked.pairing_expires_at)
      end
    end

    private_class_method :issue
  end
end
