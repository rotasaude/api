# Base das rotas /waiting_room/* (ADR 0050; contrato §8 e §14 Q8). SEM
# Authentication: o pareamento e o painel da TV vivem sem cookie de sessão e
# sem CSRF (o padrão do Hl7::BaseController: host da cidade, limite pelo
# Rails.cache). As rotas de administração (DisplaysController) incluem
# Authentication e MfaStepUp elas mesmas. Cada controller declara o
# interruptor (require_waiting_room!) na ordem que precisa: no admin depois da
# sessão; na TV depois do limite.
module WaitingRoom
  class BaseController < ApplicationController
    include ::WaitingRoomGate

    wrap_parameters false

    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422.
    FAILURE_STATUS = { missing_role: :forbidden, not_found: :not_found, call_location_name_taken: :conflict }.freeze

    private

    # `{ error, path?, problems? }` (P23).
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { path: path, error: error.to_s } ] }, status: :unprocessable_entity
    end

    def too_many_requests = render(json: { error: "too_many_requests" }, status: :too_many_requests)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def body = request.request_parameters.except("controller", "action", "id")
  end
end
