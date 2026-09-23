# Sessão do cidadão no canal web (spec 2026-09-22-web-citizen-channel §2.6).
# Cookie e tabela próprios (`citizen_session`, citizen_sessions): nada aqui lê
# o `session_id` dos servidores da cidade, e vice-versa. Roda depois de
# CityResolution, então a sessão é procurada no banco da cidade do host.
module CitizenAuthentication
  extend ActiveSupport::Concern

  COOKIE = :citizen_session
  WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze

  included do
    before_action :require_json_for_writes
    before_action :require_citizen_session
  end

  class_methods do
    def allow_anonymous_citizen(**options)
      skip_before_action :require_citizen_session, **options
    end
  end

  private

  def current_citizen_session
    Current.citizen_session ||= CitizenSession.resume(cookies.signed[COOKIE])
  end

  def require_citizen_session
    return render(json: { error: "unauthenticated" }, status: :unauthorized) unless current_citizen_session

    # Prazo deslizante também no navegador: o cookie acompanha a sessão.
    write_citizen_cookie(cookies.signed[COOKIE])
  end

  # Toda escrita é JSON: um formulário de outro site não consegue mandar
  # application/json sem preflight de CORS.
  def require_json_for_writes
    return unless WRITE_METHODS.include?(request.request_method)
    return if request.media_type == "application/json"

    render json: { error: "json_required" }, status: :unsupported_media_type
  end

  def write_citizen_cookie(token)
    cookies.signed[COOKIE] = {
      value: token,
      httponly: true,
      same_site: :lax,
      secure: Rota.deployed?,
      expires: CitizenSession::TTL.from_now
    }
  end

  def clear_citizen_cookie
    cookies.delete(COOKIE)
  end
end
