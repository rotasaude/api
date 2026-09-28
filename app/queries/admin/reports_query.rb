# GET /admin/api/reports — lista de relatórios (F-04.6). Metadados APENAS.
# NUNCA expõe token/url/payload/signature (LGPD, como o painel de triages).
#
# Filtro de bairro (ADR 0023): pelo bairro copiado na triagem do relatório.
# Com o filtro ligado, a lista sai `null` sempre que QUALQUER contagem do
# painel sair suprimida — não só quando o total é 1 a 4 — porque uma linha
# listada revelaria uma categoria suprimida no mesmo payload (mesma ideia da
# amostra em Classificação). Este painel só tem uma contagem, `total`, então
# na prática a regra é "null quando o total é 1 a 4".
class Admin::ReportsQuery
  def self.call(period:, filter: Admin::NeighborhoodFilter.off)
    new(period, filter).call
  end

  def initialize(period, filter)
    @period = period
    @filter = filter
  end

  def call
    rows = @filter.report_snapshots(ReportSnapshot.all)
             .where(created_at: @period.from..@period.to)
             .includes(:protocol_definition)
             .order(created_at: :desc)
             .to_a
    total = @filter.count(rows.size)
    { reports: suppressed_anywhere?(total) ? nil : rows.map { |r| serialize(r) }, total: total }
  end

  private

  def suppressed_anywhere?(node)
    node == Admin::SmallCount::SUPPRESSED
  end

  def serialize(report)
    {
      id: report.id,
      createdAt: report.created_at.iso8601,
      tier: report.outcome["tier"],
      protocol: "#{report.protocol_definition.name} · #{report.protocol_definition.version}",
      expiresAt: report.expires_at&.iso8601,
      live: report.expires_at.nil? || report.expires_at > Time.current
    }
  end
end
