# GET /urgency/queue?health_unit_id= (contrato §6 e §14 Q6): a fila da UPA
# pelo Urgency::Queue — `{ awaiting_classification, by_color, in_care }`, sem
# texto clínico e sem trilha (é polling). Lê a recepção (citizen_verifier) e
# quem tem acesso clínico na UPA (2235* ou 225*). Só o id da unidade na query.
module Urgency
  class QueueController < BaseController
    def show
      return unless query_only!("health_unit_id")

      unit_id = params[:health_unit_id]
      unit = uuid?(unit_id) ? HealthUnit.find_by(id: unit_id) : nil
      return not_found unless unit
      return render(json: { error: "not_an_upa" }, status: :unprocessable_entity) unless unit.upa?

      unless Access.reception?(Current.user) || Access.clinical_link(Current.user, unit.id)
        return forbid(Current.user.has_role?("health_professional") ? "missing_link" : "missing_role")
      end

      render json: Queue.groups(unit)
    end
  end
end
