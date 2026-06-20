# Registro imutável de consentimento. Ver ADR-0012.
# Revogação preenche revoked_at; nunca DELETE.
class Consent < ApplicationRecord
  belongs_to :conversation

  encrypts :evidence    # PII em jsonb — ADR-0011

  before_validation :inherit_municipality_id, on: :create

  validates :version, :policy_text_sha, :channel, :given_at, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def active?
    revoked_at.nil?
  end

  def revoke!(at: Time.current)
    update!(revoked_at: at)
  end

  private

  # Phase 1.4 adicionou municipality_id NOT NULL; RLS WITH CHECK fora
  # do tenant levanta. Deriva do conversation para que callers (GiveConsent,
  # ConversationAdvance) não precisem repetir.
  def inherit_municipality_id
    self.municipality_id ||= conversation&.municipality_id
  end
end
