# app/models/signature_session.rb
# Sessão de assinatura do turno (ADR 0032; spec §5): token signature_session do
# PSC, cifrado com a chave da cidade, até 12 h. Uma ativa por usuário.
class SignatureSession < ApplicationRecord
  STATUSES = %w[active expired revoked].freeze
  SCOPE = "signature_session".freeze
  MAX_LIFETIME = 12.hours

  encrypts :access_token

  belongs_to :user
  belongs_to :signer_certificate

  scope :active, -> { where(status: "active") }

  def self.usable_for(user_id, now: Time.current) = active.where(user_id: user_id).where("expires_at > ?", now).first

  # Houve sessão que venceu nas últimas 24 h (motivo session_expired, e não no_session).
  def self.lapsed?(user_id, now: Time.current)
    where(user_id: user_id, status: %w[active expired]).where(expires_at: (now - 1.day)..now).exists?
  end

  def inspect = "#<SignatureSession id=#{id} status=#{status} expires_at=#{expires_at&.iso8601}>"
end
