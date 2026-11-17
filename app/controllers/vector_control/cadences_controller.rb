# /vector_control/cadences (módulo 35a, ADR 0054; contrato §5, §12; Q8): a
# cadência de visita por (bairro, risco, ponto estratégico). Só a coordenação
# (403 missing_role). GET e PUT devolvem `{ items }` de VectorCadence; o PUT
# (`{ items }`, step-up: 401 mfa_required) troca a lista inteira
# (VectorControl::SaveCadences). Sem dado de pessoa: sem trilha.
module VectorControl
  class CadencesController < BaseController
    before_action(only: :update) { query_only! }
    before_action :coordinator!
    before_action :require_step_up!, only: :update

    def index
      return unless query_only!

      render json: { items: Json.cadences(VectorCadence.all.to_a) }
    end

    def update
      unknown = (body.keys - %w[items]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = SaveCadences.call(items: body_param("items"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { items: Json.cadences(result.payload.fetch(:cadences)) }
    end
  end
end
