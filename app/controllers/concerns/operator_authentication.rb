# Autenticação de operador no console de plataforma (admin.*), contra
# Operator/OperatorSession no banco de plataforma. Ver ADR-0011.
#
# Diferenças deliberadas em relação a Authentication (usuário da cidade):
#   - operador exige TOTP a cada login: a senha só cria uma sessão PENDENTE, e só
#     sessão com mfa_verified_at autentica;
#   - cookie com nome próprio (operator_session_id) e de sessão do navegador
#     (sem `permanent`): conta privilegiada não fica logada indefinidamente;
#   - host-only, como todo cookie de sessão: NUNCA `domain:` (spec §5);
#   - o SERVIDOR também impõe um limite: uma sessão verificada só autentica até
#     OPERATOR_SESSION_TTL depois de mfa_verified_at, mesmo que o cookie
#     (sessão do navegador) ainda exista — o cookie de sessão é um limite
#     ADICIONAL, não o único.
module OperatorAuthentication
  extend ActiveSupport::Concern

  COOKIE = :operator_session_id
  PENDING_MFA_WINDOW = 10.minutes
  OPERATOR_SESSION_TTL = 12.hours

  # Tentativas de TOTP por sessão pendente; no limite a sessão é apagada e o
  # operador recomeça pela senha (Plano 3B).
  MAX_TOTP_ATTEMPTS = 5

  included do
    before_action :require_operator_authentication
  end

  class_methods do
    def allow_unauthenticated_operator_access(**options)
      skip_before_action :require_operator_authentication, **options
    end
  end

  private

  def current_operator
    Current.operator_session&.operator
  end

  def require_operator_authentication
    resume_operator_session || render(json: { error: "unauthenticated" }, status: :unauthorized)
  end

  def resume_operator_session
    Current.operator_session ||= find_verified_operator_session
  end

  def find_verified_operator_session
    id = cookies.signed[COOKIE]
    return nil unless id

    session = OperatorSession.find_by(id: id)
    return nil unless session&.mfa_verified_at && session.operator.active?
    return nil if session.mfa_verified_at <= OPERATOR_SESSION_TTL.ago

    session
  end

  def start_pending_operator_session_for(operator)
    operator.operator_sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
      write_operator_cookie(session)
    end
  end

  def write_operator_cookie(session)
    cookies.signed[COOKIE] = {
      value: session.id,
      httponly: true,
      same_site: :lax,
      secure: Rota.deployed?
    }
  end

  def terminate_operator_session
    OperatorSession.find_by(id: cookies.signed[COOKIE])&.destroy
    Current.operator_session = nil
    cookies.delete(COOKIE)
  end
end
