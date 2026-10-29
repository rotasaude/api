# Base das rotas /care_regulation/* (ADR 0044; contrato §3 em diante): sessão do
# dashboard e care_regulation ligado (403 feature_disabled). Dado do paciente
# (CPF, CNS, nome, CID, justificativa, motivo, alvo) só do corpo JSON, nunca da
# URL.
module CareRegulation
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::CareRegulationGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422 (inclui appointment_scheduled, G1).
    FAILURE_STATUS = { stale_version: :conflict, invalid_transition: :conflict,
                       quota_exhausted: :conflict, citizen_not_verified: :conflict,
                       duplicate_offer: :conflict, cnes_taken: :conflict, unit_taken: :conflict,
                       duplicate_item: :conflict,
                       cbo_not_allowed: :forbidden, not_author: :forbidden, missing_role: :forbidden,
                       not_found: :not_found }.freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    KEY_PATH_MAX = 64

    before_action :require_care_regulation!

    private

    # `{ error, path?, hint?, used? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path hint used].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Papéis da regulação (contrato §2).
    def regulator? = Current.user.has_role?("care_regulator")
    def admin? = Current.user.has_role?("municipal_admin")

    # Dado do paciente e texto livre só do corpo JSON: na query vale como
    # ausente. O padrão do Surveillance::BaseController.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (a primeira chave
    # desconhecida, truncada; só o NOME da chave, nunca o valor), nada lido da
    # URL.
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render json: { error: "invalid_request", path: unknown.to_s[0, KEY_PATH_MAX] }, status: :unprocessable_entity
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
