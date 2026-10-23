# Base das rotas /territory/* (ADR 0042; contrato §3 em diante): sessão do
# dashboard e territory_registry ligado e utilizável (403 feature_disabled).
module TerritoryRegistry
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::TerritoryRegistryGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422. `invalid_transition` fica 422 (L9) e
    # `citizen_not_verified` é 409 (R8).
    FAILURE_STATUS = { duplicate_code: :conflict, stale_version: :conflict, already_registered: :conflict,
                       cpf_taken: :conflict, cns_taken: :conflict, citizen_not_verified: :conflict,
                       cbo_not_allowed: :forbidden, out_of_scope: :forbidden,
                       not_found: :not_found }.freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    before_action :require_territory_registry!

    private

    # `{ error, path?, field? }`: path/field só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:path] = result.details[:path] if result.details[:path]
      payload[:field] = result.details[:field] if result.details[:field]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # CPF, CNS, nome, nascimento, condições de saúde, endereço etc. só do corpo
    # JSON, nunca da query string (URL vai para log de proxy e histórico): na
    # query vale como ausente. O padrão do CareLines::BaseController.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Tamanho da página das listas: padrão 50, máximo 100; inválido → 422.
    # Devolve nil depois de responder.
    def page_limit
      raw = params[:limit]
      return DEFAULT_LIMIT if raw.blank?

      value = Integer(raw.to_s, 10, exception: false)
      return value if value && value.between?(1, MAX_LIMIT)

      render_error("invalid_limit")
      nil
    end
  end
end
