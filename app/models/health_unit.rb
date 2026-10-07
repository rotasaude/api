# Unidade de saúde da cidade (ADR 0018; começo do módulo 09): cadastro mínimo
# mantido pelo municipal_admin. Desativar some das listas; atendimentos
# antigos continuam apontando para ela.
class HealthUnit < ApplicationRecord
  KINDS = %w[ubs upa hospital other].freeze
  # ADR 0030: quem passa pela escuta inicial (demanda espontânea, ou todos).
  SCREENING_SCOPES = %w[walk_in all].freeze

  # A unidade foi desativada entre a leitura e a transação.
  class Inactive < StandardError; end

  has_many :attendances, dependent: :restrict_with_error

  # ADR 0023: onde a unidade FICA (pode não estar entre os bairros que atende).
  belongs_to :neighborhood, optional: true

  before_validation { self.name = name&.strip }

  # Endereço em texto (ADR 0023; módulo 11 entrega o que o ADR 0018 deixou em
  # aberto). Tudo opcional. O CEP vem do navegador do dashboard; o api só
  # confere o formato (8 dígitos) e nunca consulta serviço de CEP.
  normalizes :address_street, :address_number, :address_complement,
             with: ->(v) { v.to_s.squish.presence }, apply_to_nil: true
  normalizes :address_zip, with: ->(v) { v.to_s.gsub(/[\s.-]/, "").presence }, apply_to_nil: true

  # CNES da unidade (ADR 0028): confirmado pela cidade a partir do retrato do
  # CNES, ou editado pelo admin. Só dígitos; único.
  normalizes :cnes, with: ->(v) { v.to_s.gsub(/\D/, "").presence }, apply_to_nil: true
  validates :cnes, format: { with: /\A\d{7}\z/ }, uniqueness: true, allow_nil: true

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }
  validates :screening_scope, inclusion: { in: SCREENING_SCOPES }
  validates :address_street, length: { maximum: 160 }
  validates :address_number, length: { maximum: 20 }
  validates :address_complement, length: { maximum: 80 }
  validates :address_zip, format: { with: /\A\d{8}\z/ }, allow_nil: true

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
