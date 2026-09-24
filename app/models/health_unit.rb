# Unidade de saúde da cidade (ADR 0018; começo do módulo 09): cadastro mínimo
# mantido pelo municipal_admin. Desativar some das listas; atendimentos
# antigos continuam apontando para ela.
class HealthUnit < ApplicationRecord
  KINDS = %w[ubs upa hospital other].freeze

  has_many :attendances, dependent: :restrict_with_error

  before_validation { self.name = name&.strip }

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }

  scope :active_units, -> { where(active: true).order(:name) }
end
