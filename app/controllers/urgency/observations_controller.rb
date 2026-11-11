# Observação da UPA (ADR 0050; contrato §4 e §12 Q2, Q3).
#
# GET /urgency/observation?health_unit_id= → 200 o mapa (Urgency::Observation.board):
# `{ beds, waiting_bed }`, sem texto clínico e sem trilha (é polling). Lê a
# recepção (citizen_verifier) de qualquer UPA e quem checa a medicação na
# unidade (2235*, 3222*, 225*; Access.observation_reader?); os demais → 403
# (Access.refusal: missing_role | missing_link | cbo_not_allowed — quem perdeu
# o vínculo nunca recebe 404). Unidade desconhecida → 404; que não é UPA →
# 422 not_an_upa. Só o id da unidade na query.
#
# POST /urgency/encounters/:id/observation { bed_id, expected_stay_id? } → 201
# `{ encounter: <detalhe> }` pelo Urgency::StartObservation (entrada ou troca de
# leito; Q15: `expected_stay_id` null/id confere o que a tela viu → 409
# observation_changed; sem a chave, a regra antiga).
# POST /urgency/encounters/:id/observation/end {} → 200 `{ encounter:
# <detalhe> }` pelo Urgency::EndObservation. Os dois só do corpo (chave
# desconhecida → 422 com o nome da chave); quem escreve tem acesso clínico,
# então o detalhe sai com o clínico e grava a trilha do encontro.
module Urgency
  class ObservationsController < BaseController
    START_KEYS = %w[bed_id expected_stay_id].freeze

    def show
      return unless query_only!("health_unit_id")

      unit_id = params[:health_unit_id]
      unit = uuid?(unit_id) ? HealthUnit.find_by(id: unit_id) : nil
      return not_found unless unit
      return render(json: { error: "not_an_upa" }, status: :unprocessable_entity) unless unit.upa?
      return forbid(Access.refusal(Current.user, unit.id).to_s) unless Access.observation_reader?(Current.user, unit.id)

      render json: Observation.board(unit)
    end

    def create
      return unless query_only! && only_keys!(START_KEYS)

      encounter = find_encounter(params[:id])
      return unless encounter

      expected = request.request_parameters.key?("expected_stay_id") ? body_param("expected_stay_id") : StartObservation::ABSENT
      result = StartObservation.call(encounter: encounter, bed_id: body_param("bed_id"), by: Current.user, expected_stay_id: expected)
      return render_failure(result) if result.failure?

      render_encounter(UrgencyEncounter.find(encounter.id), clinical: true, status: :created)
    end

    def finish
      return unless query_only! && only_keys!([])

      encounter = find_encounter(params[:id])
      return unless encounter

      result = EndObservation.call(encounter: encounter, by: Current.user)
      return render_failure(result) if result.failure?

      render_encounter(UrgencyEncounter.find(encounter.id), clinical: true)
    end
  end
end
