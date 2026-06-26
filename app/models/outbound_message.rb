# Registro de envios via WhatsApp Cloud API. Ver ADR-0014.
class OutboundMessage < ApplicationRecord
  validates :to, :template, :idempotency_key, :status, presence: true
  validates :idempotency_key, uniqueness: true

  scope :successful, -> { where(status: 200..299) }
  scope :failed,     -> { where.not(status: 200..299) }
end
