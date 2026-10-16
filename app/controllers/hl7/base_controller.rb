# Borda HL7 (ADR 0037; contrato §7): host da cidade, sem cookie, token do
# middleware no Authorization (só o hash existe). Ordem: limite por hash
# (120/min) → interruptor lab_hl7_inbound → token (ausente ou desconhecido
# 401; revogado e simulado sem fake_middleware respondem AR na mensagem).
module Hl7
  class BaseController < ApplicationController
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 120, within: 1.minute, name: "hl7_inbound", store: RateLimitStore,
               by: -> { bearer_token ? LabMiddlewareToken.digest(bearer_token) : request.remote_ip },
               with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }
    before_action :require_hl7_inbound!
    before_action :authenticate_token!

    private

    def bearer_token
      header = request.authorization.to_s
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
    end

    def require_hl7_inbound!
      return if Lab::Gate.hl7_usable?(Current.city)

      render json: { error: "feature_disabled", feature: Lab::Gate::HL7_KEY }, status: :forbidden
    end

    # A busca é pelo SHA-256 (índice único): o token em claro nunca é comparado.
    def authenticate_token!
      @token = LabMiddlewareToken.by_token(bearer_token)
      return if @token && Lab::Access.labs.exists?(id: @token.exam_provider_id)

      response.headers["WWW-Authenticate"] = "Bearer"
      render json: { error: "invalid_token" }, status: :unauthorized
    end

    def fake_allowed? = Lab::Gate.fake_middleware_usable?(Current.city)
  end
end
