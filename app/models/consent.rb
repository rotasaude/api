# Registro imutável de consentimento. Ver ADR-0012.
# Revogação preenche revoked_at; nunca DELETE.
class Consent < ApplicationRecord
  belongs_to :conversation

  encrypts :evidence    # PII em jsonb — ADR-0011

  validates :version, :policy_text_sha, :channel, :given_at, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def active?
    revoked_at.nil?
  end

  def revoke!(at: Time.current)
    update!(revoked_at: at)
  end
end
