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

  def shard = slug.to_sym

  def servable? = status == "active"
end
