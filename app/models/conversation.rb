# Conversa por (municipality_id, phone). Ver ADR-0012 + emenda ADR-0021.
class Conversation < ApplicationRecord
  belongs_to :municipality
  has_many :triages, dependent: :restrict_with_error
  has_many :consents, dependent: :restrict_with_error

  encrypts :phone, deterministic: true

  enum :state, {
    greeting:         "greeting",
    awaiting_consent: "awaiting_consent",
    consented:        "consented",
    revoked:          "revoked",
    abandoned:        "abandoned"
  }, prefix: true

  def self.for(phone, municipality_id:)
    raise ArgumentError, "municipality_id obrigatório" if municipality_id.nil?
    find_or_create_by!(municipality_id: municipality_id, phone: phone, state: %w[greeting awaiting_consent consented]) ||
      create!(municipality_id: municipality_id, phone: phone, state: :greeting)
  rescue ActiveRecord::RecordNotUnique
    where(municipality_id: municipality_id, phone: phone, state: %w[greeting awaiting_consent consented]).first!
  end

  # Mantém o método antigo como atalho deprecado durante a migração.
  def self.for_phone(phone)
    raise "Use Conversation.for(phone, municipality_id:) (ADR-0021)"
  end

  def consented?
    return false unless state_consented?
    active_consent&.version == Consents.current_version(municipality_id)
  end

  def active_consent
    consents.where(revoked_at: nil).order(given_at: :desc).first
  end
end
