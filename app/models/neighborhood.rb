# Bairro da cidade (ADR 0023). Nunca se apaga: desativa. Validações e escrita
# pelos comandos de app/commands/territory.
class Neighborhood < ApplicationRecord
  has_many :coverages, class_name: "NeighborhoodCoverage"
  has_many :health_units, through: :coverages
end
