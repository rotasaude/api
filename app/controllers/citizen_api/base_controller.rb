# Base das rotas /citizen/* (canal web do cidadão). A cidade vem do host
# (CityResolution, em ApplicationController); a sessão, do cookie
# `citizen_session` (CitizenAuthentication).
module CitizenApi
  class BaseController < ApplicationController
    include CitizenAuthentication

    # Mesmo delegador de MfaController::RateLimitStore: resolve Rails.cache a
    # cada requisição, o que torna o teto exercitável em spec.
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    private

    def render_error(code, status)
      render json: { error: code.to_s }, status: status
    end
  end
end
