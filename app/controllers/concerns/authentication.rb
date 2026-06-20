# Concern de autenticação compatível com ActionController::API.
#
# Diferenças vs. gerador padrão do Rails 8:
#   - Não registra helper_method (API mode não tem view helpers).
#   - request_authentication NÃO redireciona — devolve 401 JSON.
#   - resume_session NÃO depende de session[:return_to_after_authenticating].
#
# Ver ADR-0022.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
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
    resume_session || request_authentication
  end

  def resume_session
    Current.session ||= find_session_by_cookie
  end

  def find_session_by_cookie
    return nil unless cookies.signed[:session_id]
    Session.find_by(id: cookies.signed[:session_id])
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
      cookies.signed.permanent[:session_id] = {
        value: session.id,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?
      }
    end
  end

  def terminate_session
    Current.session&.destroy
    cookies.delete(:session_id)
  end
end
