# Pendências do envio à RNDS da sala (ADR 0047, Desvios 12 e 13; contrato §5;
# §15 V7, V8; dashboard D10). Sem nome nem trilha: só ids, vacina e situação.
#
# Uma entrada por dose da sala, a que ainda pede atenção:
#  - dose ativa: a `application`;
#  - dose cancelada com `cancellation`: a `application` enquanto não foi
#    aceita (o cancelamento espera por ela) e, depois do aceite, a
#    `cancellation`; sem `cancellation` (original `rejected`/`failed`, ou
#    nunca tentado — `RndsOutboxEntry.withdrawn`) não há nada a fazer na RNDS
#    e a dose sai das pendências e do atraso (V7).
# Entra na lista: `blocked`, `rejected`, `failed`, ou `pending` há mais de
# PENDING_AFTER (20 h). Com o interruptor `rnds_immunization` desligado,
# `pending` é `not_sent`: fora da lista e do atraso (nada sairá até ligar).
# Ligado mas inutilizável (credencial ausente ou recusada) continua contando:
# o prazo está estourando. `late` (V8, o alerta de 24 h,
# calculado na leitura como o Ledi::Alert) = não aceita e `deadline_at` vencido.
module Vaccination
  module Pending
    LISTED = %w[blocked rejected failed].freeze

    module_function

    # -> ActiveRecord::Relation<RndsOutboxEntry> (as entradas que pedem atenção, sem o corte de idade)
    def effective(room) = effective_in(RndsOutboxEntry.all).where(immunizations: { vaccine_room_id: room.id })

    # A regra acima sobre qualquer escopo da fila (a sala, ou a cidade inteira
    # no Rnds::Alert). A `application` retirada (V23) fica de fora mesmo com
    # `cancellation` (a corrida em que a dose é cancelada com a entrada em voo
    # e a validação a bloqueia antes de sair): a `cancellation` órfã também.
    def effective_in(scope)
      scope.joins(:immunization).where(<<~SQL.squish).where.not(id: RndsOutboxEntry.withdrawn.select(:id))
        (rnds_outbox.kind = 'application' AND (immunizations.cancelled_at IS NULL OR (rnds_outbox.status NOT IN ('accepted', 'rejected', 'failed')
          AND EXISTS (SELECT 1 FROM rnds_outbox c WHERE c.immunization_id = immunizations.id AND c.kind = 'cancellation'))))
        OR (rnds_outbox.kind = 'cancellation' AND EXISTS (SELECT 1 FROM rnds_outbox a WHERE a.immunization_id = immunizations.id
          AND a.kind = 'application' AND a.status = 'accepted'))
      SQL
    end

    # Entradas da lista, das doses mais recentes para as mais antigas (applied_at, id da entrada).
    def scope(room, rnds_enabled:, now: Time.current)
      listed = effective(room).where(status: LISTED)
      listed = listed.or(effective(room).where(status: "pending").where(rnds_outbox: { created_at: ...(now - Catalog::PENDING_AFTER) })) if rnds_enabled
      listed.order("immunizations.applied_at DESC, rnds_outbox.id DESC")
    end

    # -> { blocked:, rejected:, failed:, late: } (a contagem é do Rnds::Alert, a mesma do painel)
    def counts(room, rnds_enabled:, now: Time.current)
      scope = RndsOutboxEntry.joins(:immunization).where(immunizations: { vaccine_room_id: room.id })
      Rnds::Alert.counts(scope, now: now, rnds_enabled: rnds_enabled).slice(:blocked, :rejected, :failed, :late)
    end
  end
end
