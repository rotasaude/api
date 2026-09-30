# app/services/analytics.rb
# Analytics (ADR 0025): consolidação diária anônima por cidade, leitura
# suprimida e publicação do conjunto fixo na plataforma.
module Analytics
  # Fuso fixo do "dia" (api#27; spec 2026-09-30 §14): o mesmo de config.time_zone.
  TZ = "America/Sao_Paulo"

  def self.to_date(value) = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
end
