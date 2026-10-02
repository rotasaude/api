# api#38: bancos de plataforma criados pela 20260930200002 antes da correção
# guardam a regra de indicador na forma `IN (...)`, que o Postgres normaliza
# diferente da carregada de db/platform_schema.rb. Troca pela forma estável
# (array de text) para que migrações e schema produzam a mesma regra.
require_relative "20260930200002_create_city_analytics_indicators"

class NormalizeCityAnalyticsIndicatorCheck < ActiveRecord::Migration[8.1]
  NAME = "ck_city_analytics_indicators_indicator"
  LEGACY = "indicator IN (#{CreateCityAnalyticsIndicators::INDICATORS.map { |i| "'#{i}'" }.join(', ')})"

  def up
    remove_check_constraint :city_analytics_indicators, name: NAME
    add_check_constraint :city_analytics_indicators, CreateCityAnalyticsIndicators.indicator_check, name: NAME
  end

  def down
    remove_check_constraint :city_analytics_indicators, name: NAME
    add_check_constraint :city_analytics_indicators, LEGACY, name: NAME
  end
end
