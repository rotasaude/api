# Unidade de saúde da cidade (ADR 0018; começo do módulo 09): cadastro mínimo
# mantido pelo municipal_admin. Desativar some das listas; atendimentos
# antigos continuam apontando para ela.
class HealthUnit < ApplicationRecord
  # ADR 0046: `ceo` (Centro de Especialidades Odontológicas), com perfil próprio.
  # ADR 0048: `health_management` (secretaria ou central de regulação), a
  # unidade de faturamento do TFD — sem atendimento, nunca APS.
  # ADR 0049: `caps` (Centro de Atenção Psicossocial), sempre com a modalidade;
  # a classificação do serviço (3 dígitos do CNES) só no CAPS. Só as
  # modalidades III e AD III/IV têm acolhimento noturno (leitos).
  KINDS = %w[ubs upa hospital other ceo health_management caps].freeze
  CAPS_MODALITIES = %w[caps_i caps_ii caps_iii caps_i_child caps_ad caps_ad_iii caps_ad_iv].freeze
  NIGHT_MODALITIES = %w[caps_iii caps_ad_iii caps_ad_iv].freeze
  SERVICE_CLASSIFICATION = /\A\d{3}\z/
  # Contrato P27: telefone da unidade, só dígitos (DDD + número), opcional.
  PHONE = /\A\d{10,11}\z/
  # ADR 0030: quem passa pela escuta inicial (demanda espontânea, ou todos).
  SCREENING_SCOPES = %w[walk_in all].freeze
  # Módulo 32a (Valor fixado 4): prefixo da senha da sala de espera.
  TICKET_PREFIX = /\A[A-Z]{1,3}\z/

  # A unidade foi desativada entre a leitura e a transação.
  class Inactive < StandardError; end

  has_many :attendances, dependent: :restrict_with_error
  # Módulo 32a (ADR 0050): locais de chamada e TVs da sala de espera.
  has_many :call_locations, dependent: :restrict_with_error
  has_many :waiting_room_displays, dependent: :restrict_with_error
  has_one :ceo_profile, inverse_of: :health_unit, dependent: :restrict_with_error

  # ADR 0045: `dispenses` marca a unidade com farmácia (local de estoque
  # `unit`, Pharmacy::SaveLocation). Padrão falso.

  # ADR 0023: onde a unidade FICA (pode não estar entre os bairros que atende).
  belongs_to :neighborhood, optional: true

  before_validation { self.name = name&.strip }
  # ADR 0043 (R7, contrato K11): a unidade de atenção primária nasce
  # notificadora quando ninguém disse o contrário. Vale para toda criação
  # (controller, Cnes::Apply, seed), por isso mora aqui e não só no controller.
  before_validation :default_notifying, on: :create
  # Módulo 32a (contrato §1): a UPA nasce com a senha U e os tempos na TV.
  before_validation :default_waiting_room, on: :create

  # Endereço em texto (ADR 0023; módulo 11 entrega o que o ADR 0018 deixou em
  # aberto). Tudo opcional. O CEP vem do navegador do dashboard; o api só
  # confere o formato (8 dígitos) e nunca consulta serviço de CEP.
  normalizes :address_street, :address_number, :address_complement,
             with: ->(v) { v.to_s.squish.presence }, apply_to_nil: true
  normalizes :address_zip, with: ->(v) { v.to_s.gsub(/[\s.-]/, "").presence }, apply_to_nil: true

  # CNES da unidade (ADR 0028): confirmado pela cidade a partir do retrato do
  # CNES, ou editado pelo admin. Só dígitos; único.
  normalizes :cnes, with: ->(v) { v.to_s.gsub(/\D/, "").presence }, apply_to_nil: true
  normalizes :phone, with: ->(v) { v.to_s.gsub(/\D/, "").presence }, apply_to_nil: true
  validates :cnes, format: { with: /\A\d{7}\z/ }, uniqueness: true, allow_nil: true

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }
  validates :screening_scope, inclusion: { in: SCREENING_SCOPES }
  validates :ticket_prefix, format: { with: TICKET_PREFIX }
  validates :show_wait_times, inclusion: { in: [ true, false ] }
  validates :address_street, length: { maximum: 160 }
  validates :address_number, length: { maximum: 20 }
  validates :address_complement, length: { maximum: 80 }
  validates :address_zip, format: { with: /\A\d{8}\z/ }, allow_nil: true
  validates :phone, format: { with: PHONE }, allow_nil: true
  # Espelho de ck_health_units_caps.
  validates :caps_modality, inclusion: { in: CAPS_MODALITIES }, if: :caps?
  validates :caps_modality, absence: true, unless: :caps?
  validates :service_classification, format: { with: SERVICE_CLASSIFICATION }, allow_nil: true, if: :caps?
  validates :service_classification, absence: true, unless: :caps?

  scope :active_units, -> { where(active: true).order(:name) }

  # Segura a unidade ativa até o fim da transação (FOR SHARE). Quem liga
  # trabalho novo à unidade (check-in, encaminhamento) chama isto dentro da
  # transação; a desativação trava a mesma linha com FOR UPDATE, então um
  # espera o outro: ou a desativação vê o atendimento/pedido novo e recusa,
  # ou o comando relê a unidade já inativa e levanta Inactive.
  def self.lock_active!(id)
    where(active: true).lock("FOR SHARE").find_by(id: id) || raise(Inactive)
  end

  def caps? = kind == "caps"
  def upa? = kind == "upa"
  def night_capable? = caps? && NIGHT_MODALITIES.include?(caps_modality)

  private

  def default_notifying
    self.notifying = (kind == "ubs") unless attribute_came_from_user?("notifying")
  end

  def default_waiting_room
    return unless upa?

    self.ticket_prefix = "U" unless attribute_came_from_user?("ticket_prefix")
    self.show_wait_times = true unless attribute_came_from_user?("show_wait_times")
  end
end
