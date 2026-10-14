# POST /exams/orders/:id/{schedule,collect,cancel} pela unidade (contrato §3).
# Cancelar: unidade ou solicitante.
module Exams
  class OrderStepsController < BaseController
    before_action :load_order

    def schedule
      return forbid("not_unit_staff") unless unit_staff?

      respond(Exams::Steps.schedule(order: @order, params: params, actor_user: Current.user))
    end

    def collect
      return forbid("not_unit_staff") unless unit_staff?

      respond(Exams::Steps.collect(order: @order, actor_user: Current.user))
    end

    def cancel
      return forbid("not_unit_staff") unless unit_staff? || @order.requester_user_id == Current.user.id

      respond(Exams::Steps.cancel(order: @order, reason: params[:reason], actor_user: Current.user))
    end

    private

    def unit_staff? = Exams::Access.unit_staff?(Current.user, @order.unit_id)

    def load_order
      @order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      not_found unless @order
    end

    def respond(result)
      return render_failure(result) if result.failure?

      grant = Exams::Access.for_order(user: Current.user, order: @order.reload)
      Exams::Trail.viewed!(order: @order, user: Current.user, grant: grant) # só a visão clínica grava
      render json: Exams::Json.order(@order, view: grant&.view || :administrative, user: Current.user)
    end
  end
end
