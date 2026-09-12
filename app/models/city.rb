# Uma cidade no catálogo de plataforma. O `slug` é, ao mesmo tempo, o
# subdomínio que a resolve e o nome do shard no connection handler.
class City < PlatformRecord
  STATUSES = %w[provisioning active suspended archived].freeze

  encrypts :database_url
  encrypts :encryption_key

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
