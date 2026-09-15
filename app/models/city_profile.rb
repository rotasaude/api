# Identidade da cidade no banco dela — linha única (ver CreateCityProfile).
# Escrita pelo provisionamento (Plano 4) e pelos seeds de dev. O destino do alerta
# NÃO mora aqui: continua sendo o AlertRecipient (R37).
class CityProfile < ApplicationRecord
  self.table_name = "city_profile"

  validates :name, presence: true
  validates :uf, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true
  validates :ibge_code, format: { with: /\A\d{7}\z/ }, allow_nil: true

  def self.current = first
end
