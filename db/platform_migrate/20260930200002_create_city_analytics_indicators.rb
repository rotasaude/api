# Conjunto fixo de indicadores semanais da cidade inteira (ADR 0025; spec
# 2026-09-30 §3.3, §5.2), no banco de PLATAFORMA. Sem bairro, unidade,
# protocolo ou pergunta; o suprimido chega nulo — o número de 1 a 4 nunca sai
# do banco da cidade.
class CreateCityAnalyticsIndicators < ActiveRecord::Migration[8.1]
  INDICATORS = %w[triages_started triages_completed attendances_closed wait_within_30_pct no_show_pct
                  left_pct].freeze

  def change
    create_table :city_analytics_indicators, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :city_id, null: false
      t.date :week_start, null: false
      t.string :indicator, null: false
      t.decimal :value, precision: 8, scale: 2
      t.boolean :suppressed, null: false
      t.datetime :published_at, null: false
      t.index %i[city_id week_start indicator], unique: true, name: "idx_city_analytics_indicators_cell"
      t.index :week_start, name: "idx_city_analytics_indicators_week"
      t.check_constraint "indicator IN (#{INDICATORS.map { |i| "'#{i}'" }.join(', ')})",
                         name: "ck_city_analytics_indicators_indicator"
      t.check_constraint "suppressed = (value IS NULL)", name: "ck_city_analytics_indicators_suppressed"
      t.check_constraint "EXTRACT(ISODOW FROM week_start) = 1", name: "ck_city_analytics_indicators_monday"
    end
    add_foreign_key :city_analytics_indicators, :cities
  end
end
