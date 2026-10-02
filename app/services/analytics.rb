# app/services/analytics.rb
# Analytics (ADR 0025): consolidação diária anônima por cidade, leitura
# suprimida e publicação do conjunto fixo na plataforma.
module Analytics
  # Fuso do "dia" (spec 2026-09-30 §14): o da cidade (api#27). Dentro de
  # CityConnection.with, Time.zone já é o fuso dela.
  def self.tz = Time.zone.tzinfo.name

  def self.to_date(value) = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
end
