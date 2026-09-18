# Conversa por telefone, no banco da cidade. Ver ADR-0008 e ADR-0007.
# A cidade é a conexão (CityConnection), não uma coluna.
class Conversation < ApplicationRecord
  has_many :triages, dependent: :restrict_with_error
  has_many :consents, dependent: :restrict_with_error

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

  def self.for(phone)
    where(phone: phone, state: %w[greeting awaiting_consent consented]).first ||
      create!(phone: phone, state: :greeting)
  rescue ActiveRecord::RecordNotUnique
    where(phone: phone, state: %w[greeting awaiting_consent consented]).first!
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
