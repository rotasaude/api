# GET /admin/api/reports — lista de relatórios (F-04.6). Metadados APENAS.
# NUNCA expõe token/url/payload/signature (LGPD, como o painel de triages).
#
# Filtro de bairro (ADR 0023): pelo bairro copiado na triagem do relatório.
# Com o filtro ligado, a lista sai `null` sempre que QUALQUER contagem do
# painel sair suprimida — não só quando o total é 1 a 4. Isso inclui `total`
# E qualquer grupo escondido DENTRO da lista: cada linha carrega `tier` e
# `protocol`, então a própria lista é uma quebra por tier/protocolo — 6
# relatórios com 1 "urgente" mostraria a lista e revelaria urgent=1, que a
# Classificação suprime. Por isso a lista some também quando algum tier ou
# algum protocolo tem 1 a 4 linhas (mesmo com o total geral visível).
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
    { reports: suppress_list?(rows, total) ? nil : rows.map { |r| serialize(r) }, total: total }
  end

  private

  def suppress_list?(rows, total)
    return false unless @filter.active?
    return true if total == Admin::SmallCount::SUPPRESSED

    small_group?(rows) { |r| r.outcome["tier"] } ||
      small_group?(rows) { |r| "#{r.protocol_definition.name} · #{r.protocol_definition.version}" }
  end

  def small_group?(rows)
    rows.group_by { |r| yield(r) }.values.any? { |group| Admin::SmallCount.small?(group.size) }
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
