# Agregados pré-computados para painéis municipais. Ver ADR-0007.
# Atualização incremental por UpdateDashboardJob; reconstrução total por script.
class DashboardMetric < ApplicationRecord
  validates :dimension, :period, :key, presence: true

  def self.bump!(municipality_id:, dimension:, period:, key:, by: 1)
    upsert(
      {
        municipality_id: municipality_id,
        dimension: dimension,
        period: period,
        key: key,
        value: by,
        updated_at: Time.current
      },
      on_duplicate: Arel.sql("value = dashboard_metrics.value + EXCLUDED.value, updated_at = EXCLUDED.updated_at"),
      unique_by: %i[municipality_id dimension period key]
    )
  end
end
