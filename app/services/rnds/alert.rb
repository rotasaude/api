# Alerta de 24 h do envio à RNDS (ADR 0047, Desvio 13; §15 V8, V23): contagem
# calculada na leitura, como o Ledi::Alert (sem notificação ativa). Mesma regra
# das pendências da sala (Vaccination::Pending.effective_in): doses sem nada a
# fazer na RNDS (original recusado/falho e cancelado, nunca tentado e
# cancelado, cancelamento órfão) ficam de fora.
#
#   late = não `accepted` e `deadline_at` vencido, INCLUINDO `sending` (V23).
#   Com o interruptor `rnds_immunization` desligado (`rnds_enabled: false`),
#   `pending` é `not_sent` e não conta como atraso; ligado mas inutilizável
#   (credencial recusada) conta.
#   pending = `pending` + `sending` (em voo ainda não é aceita).
module Rnds
  module Alert
    module_function

    # -> { pending:, blocked:, rejected:, failed:, late: }
    def counts(scope = RndsOutboxEntry.all, now: Time.current, rnds_enabled: true)
      base = Vaccination::Pending.effective_in(scope)
      by_status = base.group("rnds_outbox.status").count
      late = base.where.not(status: "accepted").where(rnds_outbox: { deadline_at: ...now })
      late = late.where.not(status: "pending") unless rnds_enabled
      { pending: by_status.values_at("pending", "sending").compact.sum, blocked: by_status["blocked"] || 0,
        rejected: by_status["rejected"] || 0, failed: by_status["failed"] || 0, late: late.count }
    end
  end
end
