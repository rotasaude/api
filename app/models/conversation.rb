# Conversa por telefone, no banco da cidade. Ver ADR-0008 e ADR-0007.
# A cidade é a conexão (CityConnection), não uma coluna.
class Conversation < ApplicationRecord
  has_many :triages, dependent: :restrict_with_error
  has_many :consents, dependent: :restrict_with_error

  belongs_to :citizen, optional: true

  # Canal de entrada (spec 2026-09-22-web-citizen-channel §3.3). No WhatsApp a
  # conversa é do telefone; na web, do cidadão (par CPF + telefone).
  enum :channel, { whatsapp: "whatsapp", web: "web" }, prefix: true

  encrypts :phone, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  enum :state, {
    greeting:         "greeting",
    awaiting_consent: "awaiting_consent",
    consented:        "consented",
    revoked:          "revoked",
    abandoned:        "abandoned",
    completed:        "completed",
    declined:         "declined",
    cancelled:        "cancelled"
  }, prefix: true

  ACTIVE_STATES = %w[greeting awaiting_consent consented].freeze

  def self.for(phone)
    channel_whatsapp.where(phone: phone, state: ACTIVE_STATES).first ||
      create!(phone: phone, state: :greeting, channel: "whatsapp")
  rescue ActiveRecord::RecordNotUnique
    channel_whatsapp.where(phone: phone, state: ACTIVE_STATES).first!
  end

  # Mantém o método antigo como atalho deprecado durante a migração.
  def self.for_phone(phone)
    raise "Use Conversation.for(phone) (ADR-0007)"
  end

  def consented?
    return false unless state_consented?
    # consents.version é INTEGER; a versão vigente é String.
    active_consent&.version&.to_s == Consents.current_version
  end

  def active_consent
    consents.where(revoked_at: nil).order(given_at: :desc).first
  end
end
