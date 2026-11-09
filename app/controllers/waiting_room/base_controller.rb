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

    # O resto das recusas é 422.
    FAILURE_STATUS = { missing_role: :forbidden, not_found: :not_found, call_location_name_taken: :conflict }.freeze

    private

    # `{ error, path?, problems? }` (P23).
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # Recusa de campo da query (P23), pelo mesmo construtor dos comandos.
    def render_refusal(path) = render_failure(Fields.refuse(path))

    def too_many_requests = render(json: { error: "too_many_requests" }, status: :too_many_requests)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(Fields::UUID)

    def body = request.request_parameters.except("controller", "action", "id")
  end
end
