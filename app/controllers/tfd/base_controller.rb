# Base das rotas /tfd/* (ADR 0048): sessão do dashboard e `tfd` ligado
# (403 feature_disabled). Dado do paciente (CPF, CNS, nome, acompanhante, laudo)
# só do corpo JSON, nunca da URL. O padrão do Vaccination::BaseController.
module Tfd
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::TfdGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422.
    FAILURE_STATUS = { already_exists: :conflict, already_closed: :conflict, same_user: :forbidden, missing_role: :forbidden,
                       not_found: :not_found }.freeze
    KEY_PATH_MAX = 64

    before_action :require_tfd!

    private

    # `{ error, path?, problems? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # 422 no formato uniforme: `error`/`path` no topo e `problems` com pelo menos esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { path: path, error: error.to_s } ] }, status: :unprocessable_entity
    end

    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def admin? = Current.user.has_role?("municipal_admin")

    # Dado do paciente e texto livre só do corpo JSON: na query vale como ausente.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (só o NOME da chave, truncado).
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end
  end
end
