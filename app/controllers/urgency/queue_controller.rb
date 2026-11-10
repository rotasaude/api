# GET /urgency/queue?health_unit_id= (contrato §6 e §14 Q6): a fila da UPA
# pelo Urgency::Queue — `{ awaiting_classification, by_color, in_care }`, sem
# texto clínico e sem trilha (é polling). Lê a recepção (citizen_verifier) e
# quem checa a medicação na UPA (2235*, 3222* ou 225*; o técnico não age). Só o id da unidade na query.
module Urgency
  class QueueController < BaseController
    def show
      return unless query_only!("health_unit_id")

      unit_id = params[:health_unit_id]
      unit = uuid?(unit_id) ? HealthUnit.find_by(id: unit_id) : nil
      return not_found unless unit
      return render(json: { error: "not_an_upa" }, status: :unprocessable_entity) unless unit.upa?

      # Fora da recepção e de quem checa a medicação (2235*, 3222*, 225*; Q2 do
      # 32b: o técnico só LÊ), a recusa: missing_role | missing_link.
      return forbid(Access.refusal(Current.user, unit.id).to_s) unless Access.observation_reader?(Current.user, unit.id)

      render json: Queue.groups(unit)
    end
  end
end
