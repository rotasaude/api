# /zoonoses/parameters (módulo 35b, ADR 0054; contrato §9, §10, Q34): GET para
# reader? → `{ version, values, created_at }` (versão 0 = defaults.yml, com
# created_at null). PUT `{ values, expected_version }` só a coordenação, com
# step-up (401 mfa_required): cria a versão seguinte (Zoonoses::SaveParameters);
# recusa → 422 invalid_parameter com o path values.<chave>; versão diferente da
# vigente → 409 parameters_changed. Sem dado de pessoa: sem trilha.
module Zoonoses
  class ParametersController < BaseController
    before_action :reader!, only: :show
    before_action :coordinator!, only: :update
    before_action :require_step_up!, only: :update

    def show
      return unless query_only!

      render json: Json.parameters(Parameters.current)
    end

    def update
      return unless query_only!

      unknown = (body.keys - %w[values expected_version]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = SaveParameters.call(values: body_param("values"), by: Current.user, expected_version: body_param("expected_version"))
      return render_failure(result) if result.failure?

      row = result.payload.fetch(:version)
      render json: Json.parameters(Parameters::Snapshot.new(version: row.version, values: row.values, created_at: row.created_at))
    end
  end
end
