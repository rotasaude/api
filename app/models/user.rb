# Identidade global (ADR-0022). PII de staff sob base de operação do serviço;
# desativação por end-dating (deactivated_at), nunca DELETE (ADR-0023).
class User < ApplicationRecord
  has_secure_password
  has_many :sessions,    dependent: :destroy
  has_many :identities,  dependent: :destroy
  has_many :memberships, dependent: :restrict_with_error  # Phase 4

  encrypts :otp_secret

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }

  def active?
    deactivated_at.nil?
  end

  def mfa_enrolled?
    otp_enabled? && otp_secret.present?
  end

  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      sessions.destroy_all
    end
  end

  # Stub. Sobrescrito no Phase 4 com memberships.platform_operator (ADR-0023).
  def operator?
    false
  end
end
