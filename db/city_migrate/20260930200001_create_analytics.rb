# Analytics (ADR 0025; spec 2026-09-30-module-14-analytics §3.1, §3.2): a
# contagem diária anônima (analytics_daily_facts), o registro de cada
# consolidação (analytics_runs) e o papel analyst no CHECK de memberships.
# Só expansão. Sem FK para unidade e bairro: o fato sobrevive à desativação
# (unidade e bairro nunca se apagam, só se desativam).
class CreateAnalytics < ActiveRecord::Migration[8.1]
  ROLES_BEFORE = %w[campaign_manager citizen_verifier health_professional municipal_admin protocol_author
                    protocol_publisher protocol_reviewer viewer].freeze
  ROLES_AFTER = %w[analyst campaign_manager citizen_verifier health_professional municipal_admin protocol_author
                   protocol_publisher protocol_reviewer viewer].freeze
  METRICS = %w[triage.started triage.completed triage.aborted attendance.checked_in attendance.closed
               attendance.wait appointment.ended request.opened request.closed calibration.outcome
               epi.answer].freeze

  def up
    replace_roles_check(ROLES_AFTER)

    create_table :analytics_daily_facts do |t|
      t.date :day, null: false
      t.string :metric, null: false
      t.uuid :health_unit_id
      t.uuid :neighborhood_id
      t.string :protocol_name
      t.integer :protocol_version
      t.string :tier
      t.string :question_id
      t.string :dim, null: false, default: ""
      t.integer :value, null: false
      t.datetime :consolidated_at, null: false
    end
    add_index :analytics_daily_facts,
              %i[day metric health_unit_id neighborhood_id protocol_name protocol_version tier question_id dim],
              unique: true, nulls_not_distinct: true, name: "idx_analytics_facts_cell"
    add_index :analytics_daily_facts, %i[metric day], name: "idx_analytics_facts_metric_day"
    add_index :analytics_daily_facts, %i[metric neighborhood_id day], name: "idx_analytics_facts_metric_neighborhood_day"
    add_index :analytics_daily_facts, %i[metric health_unit_id day], name: "idx_analytics_facts_metric_unit_day"
    add_check_constraint :analytics_daily_facts, "metric::text = ANY (ARRAY[#{quoted(METRICS)}]::text[])",
                         name: "ck_analytics_facts_metric"
    add_check_constraint :analytics_daily_facts, "value >= 1", name: "ck_analytics_facts_value"

    create_table :analytics_runs, id: :uuid do |t|
      t.date :window_from, null: false
      t.date :window_to, null: false
      t.string :kind, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.datetime :published_at
      t.string :error, limit: 500
    end
    add_index :analytics_runs, :started_at, name: "idx_analytics_runs_started_at"
    add_check_constraint :analytics_runs, "kind::text = ANY (ARRAY['scheduled', 'rebuild']::text[])",
                         name: "ck_analytics_runs_kind"
    add_check_constraint :analytics_runs, "status::text = ANY (ARRAY['running', 'succeeded', 'failed']::text[])",
                         name: "ck_analytics_runs_status"
    add_check_constraint :analytics_runs, "window_from <= window_to", name: "ck_analytics_runs_window"
  end

  def down
    drop_table :analytics_runs
    drop_table :analytics_daily_facts
    # Falha se já houver membership analyst (memberships não se apagam).
    replace_roles_check(ROLES_BEFORE)
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'" }.join(", ")

  # Mesma forma de 20260929100001: ANY (ARRAY[...]::text[]) sobrevive ao round-trip.
  def replace_roles_check(roles)
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{quoted(roles)}]::text[])",
                         name: "ck_memberships_role"
  end
end
