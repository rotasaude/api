# O "Reenviar" manual do envio da regulação à RNDS (módulo 26c, Task 14; contrato
# §5, Q16, Q25). Só `rejected` ou `failed`: volta a `queued` com `attempts 0` e
# `next_attempt_at` agora; o conteúdo (impressões digitais, situações, passos) e
# o `enqueued_at` ficam como estão (o alarme D-1 não se move). Reabre a
# contagem dos 15 dias de desistência (`reopen_retry_window!`). O evento leva
# só ids.
module Regulation
  module RetryRndsSync
    RETRYABLE = %w[rejected failed].freeze

    module_function

    # -> Result.ok(sync:) | fail(:not_retryable)
    def call(sync:, by:, now: Time.current)
      _ = by
      RegulationRndsSync.transaction do
        sync.lock!
        next Result.fail(:not_retryable) unless RETRYABLE.include?(sync.status)

        sync.update!(status: "queued", attempts: 0, next_attempt_at: now, claimed_at: nil, updated_at: now)
        sync.reopen_retry_window!
        DomainEvents.publish("regulation_rnds.queued", regulation_rnds_sync_id: sync.id, regulation_request_id: sync.regulation_request_id)
        Result.ok(sync: sync)
      end
    end
  end
end
