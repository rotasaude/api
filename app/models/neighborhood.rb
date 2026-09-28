# Bairro da cidade (ADR 0023): lista curada por cidade (semente) e editada
# pelo municipal_admin. Nunca se apaga: desativa. Inativo não entra em escolha
# nova (cidadão, cobertura), mas continua no histórico e no filtro dos
# painéis. Unicidade sem diferenciar maiúsculas: índice idx_neighborhoods_name_ci.
class Neighborhood < ApplicationRecord
  SOURCES = %w[seed manual].freeze
  NAME_MAX = 120

  has_many :coverages, class_name: "NeighborhoodCoverage"
  has_many :health_units, through: :coverages

  normalizes :name, with: ->(v) { v.to_s.squish }

  validates :name, presence: true, length: { maximum: NAME_MAX }
  validates :source, inclusion: { in: SOURCES }

  scope :active_neighborhoods, -> { where(active: true) }

  # Mesmo critério do índice único.
  def self.named(name)
    where("lower(name) = lower(?)", name.to_s.squish)
  end
end
