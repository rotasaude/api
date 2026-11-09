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

      # Fora da recepção e do clínico, a recusa do Access.classifier:
      # missing_role | missing_link | cbo_not_allowed (o técnico 3222 vinculado).
      unless Access.reception?(Current.user) || Access.clinical_link(Current.user, unit.id)
        return forbid(Access.classifier(Current.user, unit.id).reason.to_s)
      end

      render json: Queue.groups(unit)
    end
  end
end
