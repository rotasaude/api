# GET /admin/api/ingestion — webhook WhatsApp (§4.1).
#
# Limitações honestas (ver RECONCILE.md):
#  - inbound_messages NÃO tem coluna `municipality_id` → cross-tenant.
#  - inbound_messages NÃO tem `status`/`processed`/`raw_purged_at` →
#    ack[] vem vazio (ou aproximado pelos outbound_messages.status);
#    purge.pending é derivado pela IDADE da linha vs TTL configurado.
#  - dedup é null até existir contagem persistida de reentregas.
class Admin::IngestionQuery
  TTL_HOURS = 24

  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    base = InboundMessage.all.where(created_at: @period.from..@period.to)
    {
      inboundSeries: @period.series(InboundMessage.all, :created_at),
      inboundTotal: base.count,
      ack: ack_breakdown,
      dedup: nil,
      purge: purge_status
    }
  end

  private

  # Aproximação: usa outbound_messages.status como proxy de ack.
  # OutboundMessage.status é int — convertemos as faixas conhecidas.
  def ack_breakdown
    counts = OutboundMessage.where(created_at: @period.from..@period.to).group(:status).count
    [
      { code: "ok",   label: "ack ok",             count: counts.values_at(0, 1, 2).compact.sum, tone: "ok" },
      { code: "warn", label: "warning",            count: counts.values_at(3).compact.sum,       tone: "warn" },
      { code: "err",  label: "erro",               count: counts.values_at(4, 5).compact.sum,    tone: "down" }
    ]
  end

  # purge: backlog LGPD. Sem coluna `raw_purged_at` no schema, estimamos
  # pela idade do registro vs TTL. ÉTICA: isso superestima — a purga real
  # pode ter rodado. Quando a projeção de purga existir (ADR candidato),
  # esta lógica vira leitura da projeção.
  def purge_status
    cutoff = TTL_HOURS.hours.ago
    over_ttl = InboundMessage.all.where(created_at: ..cutoff)
    oldest = InboundMessage.all.minimum(:created_at)
    oldest_h = oldest ? ((Time.current - oldest) / 1.hour).round : 0
    {
      pending: over_ttl.count,
      oldestH: oldest_h,
      ttlH: TTL_HOURS,
      overTtl: oldest_h > TTL_HOURS
    }
  end
end
