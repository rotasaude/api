# /vector_control/cadences (módulo 35a, ADR 0054; contrato §5, §12; Q8): a
# cadência de visita por (bairro, risco, ponto estratégico). Só a coordenação
# (403 missing_role). GET e PUT devolvem `{ items, digest }` de VectorCadence
# (Q35: o digest da lista gravada); o PUT (`{ items, expected_digest }`,
# step-up: 401 mfa_required) troca a lista inteira (VectorControl::SaveCadences;
# 409 cadences_changed se a lista não é a que a tela leu). Sem dado de pessoa:
# sem trilha.
module VectorControl
  class CadencesController < BaseController
    before_action(only: :update) { query_only! }
    before_action :coordinator!
    before_action :require_step_up!, only: :update

    def index
      return unless query_only!

      rows = VectorCadence.all.to_a
      render json: { items: Json.cadences(rows), digest: SaveCadences.digest(rows) }
    end

    def update
      unknown = (body.keys - %w[items expected_digest]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = SaveCadences.call(items: body_param("items"), by: Current.user, expected_digest: body_param("expected_digest"))
      return render_failure(result) if result.failure?

      render json: { items: Json.cadences(result.payload.fetch(:cadences)), digest: result.payload.fetch(:digest) }
    end
  end
end
