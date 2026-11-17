# /vector_control/parameters (módulo 35a, ADR 0054; contrato §11, §12; A-4,
# A-5; Q8, Q13(8)): os parâmetros técnicos. GET para a coordenação e o agente
# de endemias (403 missing_role para os outros) → VectorParameterVersion
# `{ version, values, created_at }` (versão 0 = defaults.yml, created_at null).
# PUT `{ values }` só a coordenação, com step-up (401 mfa_required): cria a
# versão seguinte (VectorControl::SaveParameters); recusa → 422
# invalid_parameter com o path values.<chave>. Sem dado de pessoa: sem trilha.
module VectorControl
  class ParametersController < BaseController
    before_action(only: :update) { query_only! }
    before_action :reader!, only: :show
    before_action :coordinator!, only: :update
    before_action :require_step_up!, only: :update

    def show
      return unless query_only!

      render json: Json.parameters(Parameters.current)
    end

    def update
      unknown = (body.keys - %w[values]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = SaveParameters.call(values: body_param("values"), by: Current.user)
      return render_failure(result) if result.failure?

      row = result.payload.fetch(:version)
      render json: Json.parameters(Parameters::Snapshot.new(version: row.version, values: row.values, created_at: row.created_at))
    end

    private

    def reader!
      user = Current.user
      return true if Access.coordinator?(user) || Access.field_agent_somewhere?(user)

      forbid
      false
    end
  end
end
