# Base das rotas /surveillance/* (ADR 0043; contrato §3 em diante): sessão do
# dashboard e surveillance ligado (403 feature_disabled). Dado do paciente
# (CPF, CNS, nome, doença, ficha, motivo) só do corpo JSON, nunca da URL.
module Surveillance
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::SurveillanceGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422.
    FAILURE_STATUS = { already_notified: :conflict, duplicate_code: :conflict, stale_version: :conflict,
                       unit_has_notifications: :conflict, already_recorded: :conflict,
                       cpf_taken: :conflict, cns_taken: :conflict, citizen_not_verified: :conflict,
                       duplicate_suspected: :conflict,
                       cbo_not_allowed: :forbidden, not_author: :forbidden,
                       not_found: :not_found }.freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    before_action :require_surveillance!

    private

    # `{ error, path?, field?, notification_id? }`: só quando o resultado traz
    # (notification_id: a notificação existente do already_notified).
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path field notification_id].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Papel da vigilância (contrato §2).
    def surveillance? = Current.user.has_role?("surveillance")

    # Dado do paciente e texto livre só do corpo JSON: na query vale como
    # ausente. O padrão do TerritoryRegistry::BaseController.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request, nada lido da URL.
    def query_only!(*allowed)
      return true if (request.query_parameters.keys - allowed.map(&:to_s)).empty?

      render_error("invalid_request")
      false
    end

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
