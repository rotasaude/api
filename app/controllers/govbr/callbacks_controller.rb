# Callback ÚNICO do gov.br, no host auth.* (spec banco-por-cidade §5, Plano 3B).
#
#   GET /auth/govbr/callback?code=…&state=…
#     → state assinado aponta a cidade → troca o code → confere o nonce →
#       provisiona o usuário NA cidade → grant de usuário → 302 para a cidade.
#
# NÃO herda de ApplicationController: auth.* é reservado e não resolve cidade pelo
# host — a cidade vem do state.
module Govbr
  class CallbacksController < ActionController::API
    before_action :require_auth_host

    rate_limit to: 20, within: 1.minute,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def show
      state = Authenticator::GovBr.verify_state(params[:state])
      return render(json: { error: "invalid_state" }, status: :bad_request) unless state

      city = City.find_by(slug: state["city"])
      return render(json: { error: "unknown_city" }, status: :not_found) unless city&.servable?

      claims = Authenticator::GovBr.exchange_code_for_claims(params[:code].to_s)
      return render(json: { error: "invalid_nonce" }, status: :unauthorized) unless nonce_matches?(claims, state)

      user = nil
      Current.set(city: city) do
        CityConnection.with(city) { user = Authenticator::GovBr.provision_from_claims(claims) }
      end
      return render(json: { error: "govbr_unauthenticated" }, status: :unauthorized) unless user

      token = CityGrants.issue(city: city, kind: "user", subject_id: user.id)
      redirect_to CityDashboardUrl.for(city, grant: token), allow_other_host: true, status: :found
    rescue Authenticator::GovBr::IntegrationError => e
      Rails.logger.error("[govbr_callback] #{e.class}: #{e.message}")
      render json: { error: "govbr_integration_error" }, status: :bad_gateway
    end

    private

    def require_auth_host
      head :not_found unless CityCatalog.auth_host?(request.host)
    end

    def nonce_matches?(claims, state)
      nonce = claims["nonce"]
      nonce.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(nonce, state["nonce"])
    end
  end
end
