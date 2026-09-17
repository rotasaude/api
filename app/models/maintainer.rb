# Conta da API de manutenção (spec §6). Papel único e TOTAL: não há papel a
# guardar, então o que protege é a autenticação — TOTP obrigatório, bloqueio por
# conta e desativação que mata sessão na hora.
#
# Espelha Operator sem herdar: são planos diferentes (o console opera produção;
# esta ferramenta não existe lá), e juntar os dois numa tabela só faria uma conta
# de console valer aqui.
class Maintainer < PlatformRecord
  # validations: false — o mantenedor nasce pelo convite, ainda sem senha; a
  # senha chega no aceite (Task 5), e `enrolled?` é quem decide se ele loga.
  has_secure_password validations: false

  has_many :maintainer_sessions, dependent: :destroy
  has_many :maintainer_invitations, dependent: :destroy

  # Mesma custódia de Operator#otp_secret: chave da PLATAFORMA, fixa, porque
  # este atributo pode ser lido de dentro de CityConnection.with.
  encrypts :otp_secret, key_provider: PlatformKeyProvider.new

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }

  LOCKOUT_ATTEMPTS = 5
  LOCKOUT_WINDOW = 15.minutes

  scope :active, -> { where(deactivated_at: nil) }

  def active? = deactivated_at.nil?

  # Só loga quem tem senha E TOTP confirmado: um convite aceito pela metade não
  # abre sessão.
  def enrolled? = password_digest.present? && otp_secret.present? && otp_enabled_at.present?

  def locked? = locked_until.present? && locked_until > Time.current

  # Incremento atômico: duas tentativas simultâneas contam duas. O bloqueio é da
  # CONTA (o rate_limit do controller é por IP, e trocar de IP é barato).
  def register_failure!
    self.class.where(id: id).update_all(<<~SQL.squish)
      failed_attempts = failed_attempts + 1,
      locked_until = CASE WHEN failed_attempts + 1 >= #{LOCKOUT_ATTEMPTS}
                          THEN now() + interval '#{LOCKOUT_WINDOW.to_i} seconds' ELSE locked_until END,
      updated_at = now()
    SQL
  end

  # register_failure! escreve por update_all, então os atributos em memória aqui
  # estão velhos: um update! direto não veria mudança nenhuma e não escreveria
  # nada. O reload traz o estado real antes de zerar.
  def clear_failures!
    reload
    update!(failed_attempts: 0, locked_until: nil)
  end

  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      maintainer_sessions.destroy_all
    end
  end

  # Guarda do "ninguém tranca todo mundo para fora": o último mantenedor ativo
  # não pode ser desativado (spec §6).
  def last_active? = active? && self.class.active.where.not(id: id).none?
end
