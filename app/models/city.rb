# Uma cidade no catálogo de plataforma. O `slug` é, ao mesmo tempo, o
# subdomínio que a resolve e o nome do shard no connection handler.
class City < PlatformRecord
  STATUSES = %w[provisioning active suspended archived].freeze

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

  def shard = slug.to_sym

  def servable? = status == "active"
end
