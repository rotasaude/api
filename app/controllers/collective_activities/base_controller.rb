# Base das rotas /collective_activities/* (módulo 24b, ADR 0052; contrato §7,
# §13): sessão do dashboard e `collective_activities` utilizável (403
# feature_disabled). Dado de pessoa e texto (tema, público, prática,
# avaliação) só do corpo JSON, nunca da URL. Recusas `{ error, path?,
# candidates? }` com os status do HomeVisits::BaseController (plano, Desvio 11:
# a mesma tabela para os dois registros).
module CollectiveActivities
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::CollectiveActivitiesGate

    wrap_parameters false

    UUID = HomeVisits::BaseController::UUID
    FAILURE_STATUS = HomeVisits::BaseController::FAILURE_STATUS

    before_action :require_collective_activities!

    private

    def render_failure(result, status: {})
      payload = { error: result.reason.to_s }
      %i[path candidates].each { |key| payload[key] = result.details[key] if result.details.key?(key) }
      render json: payload, status: status.fetch(result.reason) { FAILURE_STATUS.fetch(result.reason, :unprocessable_entity) }
    end

    def render_refusal(error, path: nil, status: nil)
      payload = { error: error.to_s }
      payload[:path] = path if path
      render json: payload, status: status || FAILURE_STATUS.fetch(error.to_sym, :unprocessable_entity)
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Query com chave fora de `allowed` → 422 invalid_request, nada lido da URL.
    def query_only!(*allowed)
      return true if (request.query_parameters.keys - allowed.map(&:to_s)).empty?

      render_refusal("invalid_request")
      false
    end
  end
end
