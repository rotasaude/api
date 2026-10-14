# Ciência e filas (contrato §3, A20): pendentes do solicitante (com os negados
# dos últimos 30 dias, dashboard D7); fila da equipe (escalados das unidades
# onde o usuário é médico/enfermeiro de equipe ativa, A10). Leitura clínica:
# cada exame listado deixa clinical_record.viewed (só ids).
module Exams
  class AcknowledgementsController < BaseController
    DENIED_WINDOW = 30.days

    def create
      order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      return not_found unless order

      result = Exams::Acknowledge.call(order: order, by: Current.user, reason: params[:reason])
      return render_failure(result) if result.failure?

      render json: Exams::Json.order(order.reload, view: :clinical, user: Current.user)
    end

    def pending
      return forbid("missing_role") unless Current.user.has_role?("health_professional")

      list(ExamOrder.where(requester_user_id: Current.user.id, status: "resulted"), :author) do
        ExamOrder.where(requester_user_id: Current.user.id, status: "denied")
                 .where("status_changed_at >= ?", DENIED_WINDOW.ago).order(status_changed_at: :desc).limit(50)
      end
    end

    def team
      units = Exams::Access.team_unit_ids(Current.user)
      return forbid("not_in_team") if units.empty?

      list(ExamOrder.where(unit_id: units, status: "resulted").where.not(escalated_at: nil), :team)
    end

    private

    def list(scope, kind)
      page = Exams::OrderQuery.call(scope, params)
      grant = Exams::Access::Grant.new(view: :clinical, kind: kind, opening: nil)
      page[:orders].each { |order| Exams::Trail.viewed!(order: order, user: Current.user, grant: grant) }
      body = { orders: page[:orders].map { |o| Exams::Json.order(o, view: :clinical, user: Current.user, events: false) },
               next_before: page[:next_before] }
      body[:denied] = yield.map { |o| Exams::Json.order(o, view: :clinical, user: Current.user, events: false) } if block_given?
      render json: body
    rescue Exams::Cursor::Invalid, Exams::OrderQuery::InvalidFilter
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end
  end
end
