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
  has_many :maintenance_tokens, dependent: :destroy

  class LastActive < StandardError; end

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
  #
  # I1: bloqueio VENCIDO recomeça a contagem em 1. Sem isto, `failed_attempts`
  # ficava no teto para sempre depois do primeiro bloqueio: passados os 15
  # minutos, o próximo erro isolado já era o "quinto" e re-bloqueava a conta —
  # e nesta fatia não existe caminho de desbloqueio. A spec §6 fala em CINCO
  # FALHAS SEGUIDAS; um erro depois de um bloqueio expirado é a primeira.
  def register_failure!
    expired = "locked_until IS NOT NULL AND locked_until <= now()"
    attempts = "CASE WHEN #{expired} THEN 1 ELSE failed_attempts + 1 END"

    self.class.where(id: id).update_all(<<~SQL.squish)
      failed_attempts = #{attempts},
      locked_until = CASE WHEN (#{attempts}) >= #{LOCKOUT_ATTEMPTS}
                            THEN now() + interval '#{LOCKOUT_WINDOW.to_i} seconds'
                          WHEN #{expired} THEN NULL
                          ELSE locked_until END,
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

  # A trava vive AQUI, não na mutation: `last_active?` sozinho era consultivo, e
  # qualquer chamador novo (rake, console, mutation futura) trancaria todo mundo
  # para fora sem perceber.
  #
  # Fix round 1: `last_active?` era um SELECT sem trava dentro de uma
  # transação de isolamento padrão — duas desativações concorrentes nos dois
  # últimos mantenedores ativos liam uma a outra como ativa, as duas passavam
  # na checagem e as duas commitavam: zero mantenedores ativos, exatamente o
  # que a guarda existe para impedir (TOCTOU). A checagem "sou o último?" e a
  # desativação precisam ser uma coisa só: a trava é por transação (liberada
  # no commit OU no rollback), chaveada num literal fixo — o recurso disputado
  # é "o conjunto de mantenedores ativos", não uma linha. connection.execute,
  # nunca select_value: pg_advisory_xact_lock devolve void, e select_value
  # tentava tipar esse retorno e logava aviso de OID desconhecido (mesma razão
  # documentada em CityLifecycle::InviteAdmin, que usa a mesma mecânica).
  def deactivate!
    transaction do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(hashtext('maintainers:last_active'))")

      raise LastActive, "último mantenedor ativo" if last_active?

      update!(deactivated_at: Time.current)
      maintainer_sessions.destroy_all
      maintenance_tokens.each(&:revoke!)
    end
  end

  # Guarda do "ninguém tranca todo mundo para fora": o último mantenedor ativo
  # não pode ser desativado (spec §6).
  def last_active? = active? && self.class.active.where.not(id: id).none?
end
