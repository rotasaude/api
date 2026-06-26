# GET /admin/api/health — frescor de projeção, drift, recurring (§4.9).
#
# Sinal honesto: lê updated_at das projeções vs. limiar. recurring é a
# mesma lista exposta em /queues — cruzar com aquela rota dá o quadro
# completo (worker parado = retenção LGPD violada).
class Admin::HealthQuery
  THRESHOLDS_MIN = {
    "dashboard_metrics" => 15,
    "report_snapshots"  => 60
  }.freeze

  def self.call(municipality:)
    new(municipality).call
  end

  def initialize(municipality)
    @muni = municipality
  end

  def call
    {
      projections: projections,
      recurring: Admin::QueuesQuery.recurring_tasks,
      driftOverall: drift_overall
    }
  end

  private

  def projections
    [
      project_status(
        name: "dashboard_metrics",
        updated_at: Admin::Scoped.dashboard_metrics(@muni).maximum(:updated_at)
      ),
      project_status(
        name: "report_snapshots",
        updated_at: ReportSnapshot.maximum(:created_at)
      )
    ]
  end

  def project_status(name:, updated_at:)
    drift = updated_at ? ((Time.current - updated_at) / 60).round : nil
    threshold = THRESHOLDS_MIN.fetch(name, 30)
    {
      name: name,
      updatedAt: updated_at&.iso8601,
      driftMin: drift,
      thresholdMin: threshold,
      status: drift.nil? ? "down" : (drift > threshold ? "warn" : "ok")
    }
  end

  def drift_overall
    projections.map { |p| p[:driftMin] }.compact.max
  end
end
