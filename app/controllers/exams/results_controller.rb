# POST /exams/orders/:id/result pela unidade (contrato §3, A17): recepção ou
# profissional com vínculo na unidade do exame. Responde a visão
# administrativa (sem valores, crítico e PDF).
module Exams
  class ResultsController < BaseController
    def create
      order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      return not_found unless order
      return forbid("not_unit_staff") unless Exams::Access.unit_staff?(Current.user, order.unit_id)
      # Contrato §9/B12: resultado do laboratório municipal só pela liberação.
      return render(json: { error: "provider_uses_municipal_lab" }, status: :unprocessable_entity) if order.exam_provider&.uses_municipal_lab

      result = Exams::RegisterResult.call(order: order, source: "unit", file_id: params[:upload_id], released_on: params[:released_on],
                                          laboratory_name: params[:laboratory_name], critical: params[:critical],
                                          values: params[:values], by_user: Current.user)
      return render_failure(result) if result.failure?

      render json: Exams::Json.order(order.reload, view: :administrative, user: Current.user), status: :created
    end
  end
end
