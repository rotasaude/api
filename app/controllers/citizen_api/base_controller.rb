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

    # nil quando não veio (ou veio vazio/null: "prefiro não informar"); o id
    # quando é um bairro ativo; senão responde 422 e devolve nil (ADR 0023).
    def requested_neighborhood_id
      raw = params[:neighborhood_id]
      return nil if raw.nil? || raw == ""
      return raw if raw.is_a?(String) && Neighborhood.active_neighborhoods.exists?(id: raw)

      render_error("invalid_neighborhood", :unprocessable_entity)
      nil
    end
  end
end
