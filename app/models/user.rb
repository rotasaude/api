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
  encrypts :otp_pending_secret

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

  # Par de Maintenance::MaintainerActor#actor_kind: o evento de domínio e as
  # tabelas de protocolo dizem de qual tabela vem o id do ator.
  def actor_kind = "user"

  # Um código de TOTP vale uma vez só para esta conta, em qualquer endpoint
  # (spec do autenticador pendente §3/§4). Guarda o PASSO de 30 s consumido, e
  # nunca o código. A gravação condicional É o teste: `update_all` devolve 1
  # só quando o passo é maior que o último, então duas requisições com o mesmo
  # código não passam as duas, e um passo mais velho (ainda válido pela
  # tolerância de relógio) também é recusado. Mesmo desenho de
  # Maintainer#consume_totp!.
  def consume_totp_step!(step)
    return false if step.nil?

    self.class.where(id: id)
        .where("last_otp_step IS NULL OR last_otp_step < ?", step)
        .update_all(last_otp_step: step, updated_at: Time.current) == 1
  end

  # Consome um código do segredo ATIVO. A confirmação de matrícula usa o
  # PENDENTE e passa por Mfa::PendingEnrollment.
  def consume_totp!(code)
    consume_totp_step!(Mfa::Verify.totp_step_for(self, code))
  end
end
