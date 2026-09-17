# Concern de autenticação compatível com ActionController::API.
#
# Diferenças vs. gerador padrão do Rails 8:
#   - Não registra helper_method (API mode não tem view helpers).
#   - request_authentication NÃO redireciona — devolve 401 JSON.
#   - resume_session NÃO depende de session[:return_to_after_authenticating].
#   - sessão de operador (grant, Plano 3B) é negada por padrão: ver allow_operator_grant_access.
#
# Ver ADR-0011.
module Authentication
  extend ActiveSupport::Concern

  included do
    # before_action simples (NÃO prepend): precisa rodar DENTRO do
    # around_action :within_city herdado de ApplicationController
    # (CityResolution), nunca antes dele. A sessão mora no banco da cidade —
    # ler `sessions` fora da conexão da cidade (ex.: contra o shard bootstrap,
    # que não tem tabela nenhuma) levanta StatementInvalid em vez de devolver
    # 401. Um around_action envolve os before_actions definidos DEPOIS dele na
    # cadeia de callbacks; como CityResolution é incluído em ApplicationController
    # e cada controller que usa Authentication a inclui na sua própria classe
    # (depois, portanto, de herdar within_city), a ordem `within_city` →
    # `require_authentication` já vale com um before_action comum — prepend
    # colocaria require_authentication ANTES do around_action inteiro,
    # exatamente o defeito que esta nota documentava ao contrário.
    before_action :require_authentication

    # Sessão de operador aberta por grant (Plano 3B) é negada por padrão. Cada
    # controller libera por nome as ações de LEITURA que aceitam operador.
    class_attribute :operator_grant_actions, default: [], instance_writer: false
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end

    def allow_operator_grant_access(only: :all)
      self.operator_grant_actions = only == :all ? :all : Array(only).map(&:to_sym)
    end
  end

  private

  def authenticated?
    resume_session.present?
  end

  def current_user
    Current.user
  end

  def require_authentication
    return request_authentication unless resume_session
    return if !Current.session.operator_grant? || operator_grant_access_allowed?

    render json: { error: "operator_read_only" }, status: :forbidden
  end

  def operator_grant_access_allowed?
    actions = self.class.operator_grant_actions
    actions == :all || actions.include?(action_name.to_sym)
  end

  def resume_session
    Current.session ||= find_session_by_cookie
  end

  def find_session_by_cookie
    return nil unless cookies.signed[:session_id]

    session = Session.find_by(id: cookies.signed[:session_id])
    session if session&.usable?
  end

  def request_authentication
    render json: { error: "unauthenticated" }, status: :unauthorized
  end

  def start_new_session_for(user)
    user.sessions.create!(
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    ).tap do |session|
      Current.session = session
      write_session_cookie(session)
    end
  end

  # Host-only: NUNCA `domain:` (spec §5). Sessão de operador (grant) é de sessão
  # do navegador; a de usuário é permanent, como sempre foi.
  def write_session_cookie(session)
    jar = session.operator_grant? ? cookies.signed : cookies.signed.permanent
    jar[:session_id] = {
      value: session.id,
      httponly: true,
      same_site: :lax,
      secure: Rota.deployed?
    }
  end

  def terminate_session
    Current.session&.destroy
    cookies.delete(:session_id)
  end
end
