# Pendências do envio à RNDS da sala (ADR 0047, Desvios 12 e 13; contrato §5;
# §15 V7, V8; dashboard D10). Sem nome nem trilha: só ids, vacina e situação.
#
# Uma entrada por dose da sala, a que ainda pede atenção:
#  - dose ativa: a `application`;
#  - dose cancelada: a `application` enquanto não foi aceita (o cancelamento
#    espera por ela) e, depois do aceite, a `cancellation`; com a
#    `application` `rejected`/`failed` não há nada a desfazer na RNDS e a dose
#    sai das pendências (V7).
# Entra na lista: `blocked`, `rejected`, `failed`, ou `pending` há mais de
# PENDING_AFTER (20 h). Com o envio desligado, `pending` é `not_sent`: fora da
# lista e do atraso (nada sairá até ligar). `late` (V8, o alerta de 24 h,
# calculado na leitura como o Ledi::Alert) = não aceita e `deadline_at` vencido.
module Vaccination
  module Pending
    LISTED = %w[blocked rejected failed].freeze

    module_function

    # -> ActiveRecord::Relation<RndsOutboxEntry> (as entradas que pedem atenção, sem o corte de idade)
    def effective(room)
      RndsOutboxEntry.joins(:immunization).where(immunizations: { vaccine_room_id: room.id }).where(<<~SQL.squish)
        (rnds_outbox.kind = 'application' AND (immunizations.cancelled_at IS NULL OR (rnds_outbox.status NOT IN ('accepted', 'rejected', 'failed')
          AND EXISTS (SELECT 1 FROM rnds_outbox c WHERE c.immunization_id = immunizations.id AND c.kind = 'cancellation'))))
        OR (rnds_outbox.kind = 'cancellation' AND EXISTS (SELECT 1 FROM rnds_outbox a WHERE a.immunization_id = immunizations.id
          AND a.kind = 'application' AND a.status = 'accepted'))
      SQL
    end

    # Entradas da lista, das doses mais recentes para as mais antigas (applied_at, id da entrada).
    def scope(room, rnds_usable:, now: Time.current)
      listed = effective(room).where(status: LISTED)
      listed = listed.or(effective(room).where(status: "pending").where(rnds_outbox: { created_at: ...(now - Catalog::PENDING_AFTER) })) if rnds_usable
      listed.order("immunizations.applied_at DESC, rnds_outbox.id DESC")
    end

    # -> { blocked:, rejected:, failed:, late: }
    def counts(room, rnds_usable:, now: Time.current)
      base = effective(room)
      by_status = base.where(status: LISTED).group(:status).count
      late = base.where.not(status: "accepted").where(rnds_outbox: { deadline_at: ...now })
      late = late.where.not(status: "pending") unless rnds_usable
      { blocked: by_status["blocked"] || 0, rejected: by_status["rejected"] || 0, failed: by_status["failed"] || 0, late: late.count }
    end
  end
end
