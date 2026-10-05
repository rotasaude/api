# Uma cidade no catálogo de plataforma. O `slug` é, ao mesmo tempo, o
# subdomínio que a resolve e o nome do shard no connection handler.
class City < PlatformRecord
  STATUSES = %w[provisioning active suspended archived].freeze

  # api#27: os 16 identificadores IANA do Brasil (4 fusos, UTC-2 a UTC-5). O
  # banco recusa qualquer outro (ck_cities_time_zone, mesma lista).
  TIME_ZONES = %w[
    America/Noronha
    America/Belem America/Fortaleza America/Recife America/Araguaina America/Maceio America/Bahia
    America/Sao_Paulo America/Santarem
    America/Campo_Grande America/Cuiaba America/Porto_Velho America/Boa_Vista America/Manaus
    America/Eirunepe America/Rio_Branco
  ].freeze

  # ADR 0028 (spec 2026-10-05 §3.2): o modo é decisão de contrato, do operador
  # no console. Toda cidade nasce off.
  RECORD_MODES = %w[off integrated record].freeze
  PEC_URL_MAX = 255

  # key_provider: fixo na chave da plataforma (PlatformKeyProvider) — sem
  # isso, ler/escrever estes atributos de dentro de CityConnection.with usaria
  # a chave da cidade (o contexto de cifra é global por thread, não por
  # model). Ver comentário em app/services/platform_key_provider.rb.
  encrypts :database_url, key_provider: PlatformKeyProvider.new
  encrypts :encryption_key, key_provider: PlatformKeyProvider.new

  scope :active, -> { where(status: "active") }

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/ },
                   length: { in: 2..63 },
                   exclusion: { in: CityCatalog::RESERVED }
  validates :name, :database_url, :encryption_key, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :time_zone, inclusion: { in: TIME_ZONES }
  validates :record_mode, inclusion: { in: RECORD_MODES }
  validate { errors.add(:pec_url, :invalid) unless pec_url.nil? || self.class.valid_pec_url?(pec_url) }

  has_many :features, class_name: "CityFeature", dependent: :restrict_with_error

  # Endereço do PEC da cidade (ADR 0028): só HTTPS, sem usuário/senha na URL
  # (credencial é da cidade, cifrada no banco dela), sem query nem fragmento.
  def self.valid_pec_url?(value)
    return false unless value.is_a?(String) && value.length <= PEC_URL_MAX

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def shard = slug.to_sym

  def servable? = status == "active"
end
