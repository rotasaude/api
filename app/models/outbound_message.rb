# Registro de envios via WhatsApp Cloud API. Ver ADR-0005.
class OutboundMessage < ApplicationRecord
  # Telefone do destinatário (api#19): determinístico com a chave da cidade,
  # como InboundMessage#from. Linhas anteriores: city:encrypt_message_phones.
  encrypts :to, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  validates :to, :template, :idempotency_key, :status, presence: true
  validates :idempotency_key, uniqueness: true

  scope :successful, -> { where(status: 200..299) }
  scope :failed,     -> { where.not(status: 200..299) }
end
