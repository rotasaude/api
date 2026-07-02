# GET /admin/api/reports — lista de relatórios (F-04.6). Metadados APENAS.
# NUNCA expõe token/url/payload/signature (LGPD, como o painel de triages).
class Admin::ReportsQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    rows = Admin::Scoped.report_snapshots(@muni)
             .where(created_at: @period.from..@period.to)
             .includes(:protocol_definition)
             .order(created_at: :desc)
    { reports: rows.map { |r| serialize(r) }, total: rows.size }
  end

  private

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
