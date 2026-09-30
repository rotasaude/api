# Indicador semanal publicado de uma cidade (ADR 0025; spec 2026-09-30 §3.3).
# Escrito só por Analytics::Publish; lido pelo console do operador e pelo
# GraphQL de manutenção, que nunca abrem o banco da cidade para isso.
class CityAnalyticsIndicator < PlatformRecord
  INDICATORS = %w[triages_started triages_completed attendances_closed wait_within_30_pct no_show_pct
                  left_pct].freeze
  COUNT_INDICATORS = %w[triages_started triages_completed attendances_closed].freeze

  belongs_to :city
end
