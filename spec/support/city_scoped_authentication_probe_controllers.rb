# Controllers usados apenas pelo spec de autenticação/resolução de cidade
# (spec/requests/city_scoped_authentication_spec.rb). Ficam em support para
# não poluir app/.
#
# SignedCookiePlantController mints a validly-signed session_id cookie for an
# arbitrary value, via the exact same cookies.signed[]= path the real app
# uses (Authentication#start_new_session_for) — reusing the real signing
# machinery instead of hand-rolling ActiveSupport::MessageVerifier framing,
# which is intricate and version-sensitive.
class SignedCookiePlantController < ActionController::API
  include ActionController::Cookies

  def create
    cookies.signed[:session_id] = { value: params[:session_id], httponly: true, same_site: :lax, secure: false }
    head :no_content
  end
end

# AuthenticatedProbeController mirrors the shape of every real controller
# that needs a session (MfaController, PasswordsController, ...): it inherits
# CityResolution from ApplicationController and includes Authentication
# itself, so its callback order is exactly what production code goes
# through.
class AuthenticatedProbeController < ApplicationController
  include Authentication

  def show
    head :no_content
  end
end
