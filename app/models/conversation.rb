# Conversa por telefone, máquina de estados de consentimento. Ver ADR-0012.
class Conversation < ApplicationRecord
  has_many :triagens, dependent: :restrict_with_error
  has_many :consents, dependent: :restrict_with_error

  encrypts :phone, deterministic: true   # ADR-0011

  enum :state, {
    greeting:         "greeting",
    awaiting_consent: "awaiting_consent",
    consented:        "consented",
    revoked:          "revoked"
  }, prefix: true

  def self.for_phone(phone)
    find_or_create_by!(phone: phone) { |c| c.state = :greeting }
  end

  def consented?
    return false unless state_consented?
    active_consent&.version == Consents.current_version
  end

  def active?
    state_consented? || state_awaiting_consent?
  end

  def active_consent
    consents.where(revoked_at: nil).order(given_at: :desc).first
  end

  def current_triagem
    triagens.where(status: :in_progress).order(created_at: :desc).first
  end

  def start_triagem!(protocol_name: "triagem-respiratoria")
    record = ProtocolDefinition.where(name: protocol_name, status: "active").first!
    triagens.create!(
      protocol_definition: record,
      protocol_name: protocol_name,
      answers: {},
      current_step: Protocols.current(name: protocol_name, municipality: municipality).start_step_id.to_s,
      status: :in_progress
    )
  end

  def municipality
    Municipality.find_by(id: municipality_id) if municipality_id
  end
end
