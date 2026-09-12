# Conta de operador (staff da plataforma), na PLATAFORMA — espelha a
# autenticação e MFA de User, sem o conceito de membership por município: um
# Operator é operador por definição (não copia #operator?/#role_in?).
class Operator < PlatformRecord
  has_secure_password

  # Mesmo contrato de User#password_reset (F-06.2): signed, 15-min, single-use.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  has_many :operator_sessions, dependent: :destroy

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
      operator_sessions.destroy_all
    end
  end
end
