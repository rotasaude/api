# Unidade de saúde da cidade (ADR 0018; começo do módulo 09): cadastro mínimo
# mantido pelo municipal_admin. Desativar some das listas; atendimentos
# antigos continuam apontando para ela.
class HealthUnit < ApplicationRecord
  KINDS = %w[ubs upa hospital other].freeze

  # A unidade foi desativada entre a leitura e a transação.
  class Inactive < StandardError; end

  has_many :attendances, dependent: :restrict_with_error

  # ADR 0023: onde a unidade FICA (pode não estar entre os bairros que atende).
  belongs_to :neighborhood, optional: true

  before_validation { self.name = name&.strip }

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }

  scope :active_units, -> { where(active: true).order(:name) }

  # Segura a unidade ativa até o fim da transação (FOR SHARE). Quem liga
  # trabalho novo à unidade (check-in, encaminhamento) chama isto dentro da
  # transação; a desativação trava a mesma linha com FOR UPDATE, então um
  # espera o outro: ou a desativação vê o atendimento/pedido novo e recusa,
  # ou o comando relê a unidade já inativa e levanta Inactive.
  def self.lock_active!(id)
    where(active: true).lock("FOR SHARE").find_by(id: id) || raise(Inactive)
  end
end
