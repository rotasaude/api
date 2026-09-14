# Agregados pré-computados para o painel da cidade. Ver ADR-0010.
# Atualização incremental por UpdateDashboardJob; reconstrução total por
# RebuildDashboardMetricsJob. O banco é da cidade: a chave é (dimension, period, key).
class DashboardMetric < ApplicationRecord
  validates :dimension, :period, :key, presence: true

  def self.bump!(dimension:, period:, key:, by: 1)
    upsert(
      {
        dimension: dimension,
        period: period,
        key: key,
        value: by,
        updated_at: Time.current
      },
      on_duplicate: Arel.sql("value = dashboard_metrics.value + EXCLUDED.value, updated_at = EXCLUDED.updated_at"),
      unique_by: %i[dimension period key]
    )
  end
end
