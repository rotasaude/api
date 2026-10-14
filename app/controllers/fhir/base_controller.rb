# Borda FHIR (ADR 0036; contrato §7, A7, A15): host da cidade, sem cookie,
# token do prestador no Authorization (só o hash existe no banco; a busca é
# pelo hash). Ordem: limite por hash do token (60/min) → interruptor → token
# → prestador simulado exige fake_lab. O corpo application/fhir+json não é
# um tipo JSON registrado: o Rails não o põe em params (nem no log).
module Fhir
  class BaseController < ApplicationController
    MEDIA_TYPE = "application/fhir+json".freeze

    # `store:` é avaliado no carregamento da classe: o delegador resolve
    # Rails.cache a cada requisição (como SessionsController::RateLimitStore).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 60, within: 1.minute, name: "fhir_inbound", store: RateLimitStore,
               by: -> { bearer_token ? ExamProvider.digest(bearer_token) : request.remote_ip },
               with: -> { fhir_error("rate_limited", :too_many_requests) }
    before_action :require_fhir_inbound!
    before_action :authenticate_provider!

    private

    def bearer_token
      header = request.authorization.to_s
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
    end

    def require_fhir_inbound!
      return if Exams::Gate.fhir_usable?(Current.city)

      render json: { error: "feature_disabled", feature: Exams::Gate::FHIR_KEY }, status: :forbidden
    end

    def authenticate_provider!
      @provider = ExamProvider.by_token(bearer_token)
      unless @provider
        response.headers["WWW-Authenticate"] = "Bearer"
        return fhir_error("invalid_token", :unauthorized)
      end
      return if !@provider.simulated || Exams::Gate.fake_lab_usable?(Current.city)

      render json: { error: "feature_disabled", feature: Exams::Gate::FAKE_LAB_KEY }, status: :forbidden
    end

    def fhir_error(code, status, details: nil)
      render json: { error: code, details: details }.compact, status: status
    end
  end
end
