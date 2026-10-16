module Exams
  class GalController < BaseController
    def create
      order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      return not_found unless order

      result = Exams::RecordGal.call(order: order, value: params[:gal_requisition], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Exams::Json.order(order.reload, view: :administrative, user: Current.user)
    end
  end
end
