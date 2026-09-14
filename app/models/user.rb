# Identidade de staff da cidade (ADR-0011), no banco da cidade. PII de staff sob base de operação do serviço;
# desativação por end-dating (deactivated_at), nunca DELETE (ADR-0012).
class User < ApplicationRecord
  has_secure_password

  # F-06.2: signed, 15-min, single-use (password_salt changes on password
  # update, which invalidates any outstanding token). Explicit here even
  # though has_secure_password(reset_token: true) already registers this
  # purpose by default in Rails 8.1 — keeps the contract visible/pinned.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

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

  # Nenhum usuário de cidade é operador de plataforma: operadores são Operator,
  # no banco de plataforma (spec banco-por-cidade §5), e memberships não aceita
  # platform_operator (ck_memberships_role). Fica `false` para que o call site
  # que ainda ramifica por operador (SetupController#deactivate_user) falhe
  # fechado até o Plano 3B trazer o grant de operador para dentro da cidade.
  def operator?
    false
  end

  # Papel ativo NESTA cidade — o banco é da cidade da conexão corrente.
  def has_role?(role)
    memberships.active.exists?(role: role.to_s)
  end
end
