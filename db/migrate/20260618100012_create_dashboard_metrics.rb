# Ver ADR-0007.
class CreateDashboardMetrics < ActiveRecord::Migration[8.0]
  def change
    create_table :dashboard_metrics, id: :uuid do |t|
      t.references :municipality, type: :uuid, null: false, foreign_key: true
      t.string  :dimension, null: false   # triagens_by_tier, urgent_pending, ...
      t.string  :period,    null: false   # 2026-06-18, 2026-W24, 2026-06
      t.string  :key,       null: false   # alta/media/baixa OR total
      t.integer :value,     null: false, default: 0
      t.timestamps
    end

    add_index :dashboard_metrics,
              [:municipality_id, :dimension, :period, :key],
              unique: true,
              name: "idx_dashboard_metrics_dim_period_key"
    add_index :dashboard_metrics, [:dimension, :period]
  end
end
