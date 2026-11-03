# Destino (ADR 0048): município (IBGE, único) com a distância em km a partir
# da cidade (0 = intramunicipal) e a marca de região metropolitana (o TFD
# recusa). Nunca é apagado (trigger): desativa-se.
class TransportDestination < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"

  scope :active_destinations, -> { where(active: true) }
end
