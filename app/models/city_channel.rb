# Canal WhatsApp por cidade (ADR-0007), na PLATAFORMA. access_token via AR
# Encryption (ADR-0013). Lido ANTES de saber a cidade — por isso mora aqui, e
# não em cada banco de cidade.
class CityChannel < PlatformRecord
  belongs_to :city
  # key_provider: fixo na chave da plataforma (PlatformKeyProvider) — este
  # atributo é lido de dentro de CityConnection.with (SendWhatsappJob), e o
  # contexto de cifra da cidade é global por thread. Ver
  # app/services/platform_key_provider.rb.
  encrypts :access_token, key_provider: PlatformKeyProvider.new

  scope :active, -> { where(active: true) }

  validates :phone_number_id, :waba_id, :display_phone_number, presence: true
  validates :phone_number_id, uniqueness: true
end
