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
    before_action :require_maintenance_origin
    before_action :require_maintainer_authentication
  end

  class_methods do
    def allow_unauthenticated_maintainer_access(**options)
      skip_before_action :require_maintainer_authentication, **options
    end
  end

  private

  def current_maintainer = Current.maintainer_session&.maintainer

  # Origem exata + header próprio. Sem os dois, um formulário de outro site
  # dispararia mutation com o cookie do mantenedor.
  #
  # I3 (fix round 2): FALHA FECHADA quando a variável não está configurada. A
  # comparação direta degradava para `nil == nil` — sem MAINTENANCE_FRONTEND_ORIGIN
  # no ambiente, toda requisição SEM Origin (as que não vêm de navegador, entre
  # elas as de um script) passava pela trava de CSRF. Config ausente vira 403,
  # nunca permissão. MaintenanceApi.check_boot! torna a ausência barulhenta em
  # ambiente publicado; aqui ela é só fechada.
  def require_maintenance_origin
    expected = ENV[MaintenanceApi::ORIGIN].to_s
    return head(:forbidden) if expected.blank?
    return head(:forbidden) unless request.headers["Origin"] == expected

    head(:forbidden) unless request.headers[HEADER] == "1"
  end

  def require_maintainer_authentication
    resume_maintainer_session || render(json: { error: "unauthenticated" }, status: :unauthorized)
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
