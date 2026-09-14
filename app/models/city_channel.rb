# Canal WhatsApp por cidade (ADR-0007), na PLATAFORMA. access_token via AR
# Encryption (ADR-0013). Lido ANTES de saber a cidade — por isso mora aqui, e
# não em cada banco de cidade.
class CityChannel < PlatformRecord
  belongs_to :city
  encrypts :access_token

  scope :active, -> { where(active: true) }

  validates :phone_number_id, :waba_id, :display_phone_number, presence: true
  validates :phone_number_id, uniqueness: true
end
