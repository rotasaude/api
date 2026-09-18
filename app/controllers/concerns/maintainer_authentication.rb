# Autenticação do mantenedor na API de manutenção (spec §6), contra
# Maintainer/MaintainerSession no banco de plataforma.
#
# Diferenças deliberadas em relação a OperatorAuthentication:
#   - sessão mais CURTA: 8h absolutas desde o TOTP e 30 min de inatividade. O
#     operador tem 12h; aqui os poderes são totais;
#   - SameSite=Strict (o operador usa :lax): nenhuma navegação de terceiro
#     carrega esta sessão;
#   - CSRF explícito: Origin exatamente igual ao frontend do ambiente MAIS o
#     header X-Rota-Maintenance, que força preflight. A API é servida em outra
#     origem que o frontend, então SameSite sozinho não basta — os dois estão no
#     mesmo site (rotasaude.com.br), e os três ambientes também;
#   - host-only, como todo cookie de sessão: NUNCA `domain:`.
module MaintainerAuthentication
  extend ActiveSupport::Concern

  COOKIE = :maintainer_session_id
  HEADER = "X-Rota-Maintenance"
  PENDING_MFA_WINDOW = 10.minutes
  ABSOLUTE_TTL = 8.hours
  IDLE_TTL = 30.minutes
  MAX_TOTP_ATTEMPTS = 5

  included do
    before_action :resolve_maintenance_credential
    before_action :require_maintenance_origin
    before_action :require_maintainer_authentication
  end

  class_methods do
    def allow_unauthenticated_maintainer_access(**options)
      skip_before_action :require_maintainer_authentication, **options
    end
  end

  private

  BEARER = /\ABearer (.+)\z/

  def current_maintainer = Current.maintenance_credential&.maintainer

  # I5 (spec §9): `request_id` e `ip` fazem parte do payload de auditoria — são
  # o que liga uma linha da trilha à requisição no log da aplicação. Nenhuma
  # das duas chaves esbarra na Ruling R18.
  def audit_request_fields = { request_id: request.request_id, ip: request.remote_ip }

  # Cookie OU bearer, nunca os dois: com as duas credenciais presentes não há
  # resposta honesta para "quem agiu", e a auditoria é o que resta quando os
  # poderes são totais (spec §7).
  #
  # Fix round 1 (I2): RESOLVER não escreve. `touch_session` saiu daqui — antes
  # rodava aqui, ANTES da checagem de Origin, então um cookie válido com Origin
  # errado ainda renovava a janela de inatividade da vítima sem nunca passar
  # pela trava de CSRF. Quem toca a sessão agora é
  # `require_maintainer_authentication`, que só roda depois da origem aprovar.
  def resolve_maintenance_credential
    bearer = request.headers["Authorization"].to_s[BEARER, 1]
    cookie = cookies.signed[COOKIE]

    return render(json: { error: "ambiguous_credentials" }, status: :unauthorized) if bearer && cookie

    return resolve_token_credential(bearer) if bearer

    session = find_verified_session
    return unless session

    Current.maintainer_session = session
    Current.maintenance_credential = Maintenance::Credential.session(session)
  end

  def resolve_token_credential(secret)
    token = MaintenanceToken.authenticate(secret)
    unless token
      audit_refused_bearer(secret)
      return render(json: { error: "unauthenticated" }, status: :unauthorized)
    end

    token.touch_use!(ip: request.remote_ip)
    Current.maintenance_credential = Maintenance::Credential.token(token)
  end

  # Fix round 1 (Critical): NUNCA ecoa o valor apresentado. O prefixo gravado é
  # a constante DESTE ambiente, nunca um pedaço do que chegou no header.
  #
  # Fix round 2 (C1): e só audita o que tem a CARA de um token deste ambiente.
  # A versão anterior gravava uma linha por bearer recusado, inclusive por lixo
  # de prober — em `maintenance.%`, que o trigger torna indelével: qualquer um,
  # sem credencial nenhuma, fazia o banco de plataforma crescer e afogava
  # `auditEvents` (teto de 200, mais novos primeiro). Um evento que diz só
  # "unrecognized" não carrega informação; o que interessa é alguém insistindo
  # com um segredo do formato certo, e ESSE continua sendo gravado, um por
  # tentativa. Para o resto sobram o 401 e o teto por IP da controller.
  def audit_refused_bearer(secret)
    return unless secret.to_s.start_with?(MaintenanceToken.prefix)

    # Sem maintainer_id: um segredo recusado não identifica ninguém.
    MaintenanceAudit.record("maintenance.token.refused", outcome: "rejected", module_name: "token",
                            maintainer_id: nil, credential: { "kind" => "token" },
                            token_prefix: MaintenanceToken.prefix, **audit_request_fields)
  end

  # Fix round 1 (I3), estendido no round 2 (M7): endpoints do NAVEGADOR —
  # cookie, TOTP, bloqueio por conta — recusam bearer. Um token de serviço se
  # identifica pela query GraphQL `me`, nunca por ali. Mora no concern porque
  # `SessionsController` e `InvitationsController` precisam da MESMA trava: em
  # `/invitations/*` um bearer era aceito e, por ser token, ainda pulava a
  # checagem de Origin logo abaixo.
  def require_browser_credential
    return unless Current.maintenance_credential&.token?

    render json: { error: "browser_only" }, status: :forbidden
  end

  # A trava de CSRF é do NAVEGADOR. Um token não tem Origin nem cookie, então
  # exigir os dois dele recusaria toda automação; o que protege o token é ele
  # próprio ser secreto e não viajar sozinho como o cookie viaja.
  #
  # I3 (fix round 2): FALHA FECHADA quando a variável não está configurada. A
  # comparação direta degradava para `nil == nil` — sem MAINTENANCE_FRONTEND_ORIGIN
  # no ambiente, toda requisição SEM Origin (as que não vêm de navegador, entre
  # elas as de um script) passava pela trava de CSRF. Config ausente vira 403,
  # nunca permissão. MaintenanceApi.check_boot! torna a ausência barulhenta em
  # ambiente publicado; aqui ela é só fechada.
  def require_maintenance_origin
    return if Current.maintenance_credential&.token?

    expected = ENV[MaintenanceApi::ORIGIN].to_s
    return head(:forbidden) if expected.blank?
    return head(:forbidden) unless request.headers["Origin"] == expected

    head(:forbidden) unless request.headers[HEADER] == "1"
  end

  def require_maintainer_authentication
    credential = Current.maintenance_credential
    return render(json: { error: "unauthenticated" }, status: :unauthorized) unless credential

    # Fix round 1 (I2): o toque na sessão mora AQUI agora, depois que a Origin
    # já foi aprovada (este before_action roda por último) — nunca antes dela.
    touch_session(Current.maintainer_session) if credential.human?
  end

  def resume_maintainer_session
    Current.maintainer_session ||= find_verified_session&.tap { |session| touch_session(session) }
  end

  def find_verified_session
    id = cookies.signed[COOKIE]
    return nil unless id

    session = MaintainerSession.find_by(id: id)
    return nil unless session&.mfa_verified_at && session.maintainer.active?
    return nil if session.mfa_verified_at <= ABSOLUTE_TTL.ago
    return nil if (session.last_seen_at || session.mfa_verified_at) <= IDLE_TTL.ago

    session
  end

  # A inatividade é medida no SERVIDOR: o cookie é de sessão do navegador, que
  # some ao fechar, mas quem decide é a linha no banco.
  def touch_session(session)
    session.update_columns(last_seen_at: Time.current)
  end

  def start_pending_session_for(maintainer)
    maintainer.maintainer_sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip)
              .tap { |session| write_maintenance_cookie(session) }
  end

  def write_maintenance_cookie(session)
    cookies.signed[COOKIE] = {
      value: session.id,
      httponly: true,
      same_site: :strict,
      secure: Rota.deployed?
    }
  end

  def terminate_maintenance_session
    MaintainerSession.find_by(id: cookies.signed[COOKIE])&.destroy
    Current.maintainer_session = nil
    cookies.delete(COOKIE)
  end
end
