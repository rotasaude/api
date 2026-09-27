# GET /admin/api/ingestion — webhook WhatsApp (§4.1, F-01.10): volume inbound,
# ack aproximado e backlog de purga do raw.
#
# Limitações honestas (ver RECONCILE.md):
#  - inbound_messages mora no banco da cidade do host: sem filtro, lê só aquela cidade.
#  - conta só o webhook do WhatsApp; o canal web do cidadão (ADR 0017) não entra.
#  - inbound_messages NÃO tem `status`/`processed` → ack vem aproximado pelos
#    outbound_messages.status.
class Admin::IngestionQuery
  # A janela do backlog é a retenção real do raw, uma fonte só (ADR-0014).
  TTL_HOURS = PurgeInboundRawJob::RAW_RETENTION_DAYS * 24

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    base = InboundMessage.all.where(created_at: @period.from..@period.to)
    {
      inboundSeries: @period.series(InboundMessage.all, :created_at),
      inboundTotal: base.count,
      ack: ack_breakdown,
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

  # purge: backlog LGPD. PurgeInboundRawJob zera o raw e mantém a linha, então
  # só conta (e só mede idade de) linha com raw ainda guardado.
  def purge_status
    stored = InboundMessage.where.not(raw: nil)
    over_ttl = stored.where(created_at: ..TTL_HOURS.hours.ago)
    oldest = stored.minimum(:created_at)
    oldest_h = oldest ? ((Time.current - oldest) / 1.hour).round : 0
    {
      pending: over_ttl.count,
      oldestH: oldest_h,
      ttlH: TTL_HOURS,
      overTtl: oldest_h > TTL_HOURS
    }
  end
end
