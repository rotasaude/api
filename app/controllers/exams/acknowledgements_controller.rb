# Ciência e filas (contrato §3, A20): pendentes do solicitante (com os negados
# dos últimos 30 dias, dashboard D7); fila da equipe (escalados das unidades
# onde o usuário é médico/enfermeiro de equipe ativa, A10). Leitura clínica:
# cada exame listado deixa clinical_record.viewed (só ids).
module Exams
  class AcknowledgementsController < BaseController
    DENIED_WINDOW = 30.days
    PAGE = 50 # tamanho da página (padrão de Timeline::Query.limit) e teto dos negados

    def create
      order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      return not_found unless order

      result = Exams::Acknowledge.call(order: order, by: Current.user, reason: params[:reason])
      return render_failure(result) if result.failure?

      order.reload
      Exams::Trail.viewed!(order: order, user: Current.user, grant: Exams::Access.for_order(user: Current.user, order: order))
      render json: Exams::Json.order(order, view: :clinical, user: Current.user)
    end

    def pending
      return forbid("missing_role") unless Current.user.has_role?("health_professional")

      list(ExamOrder.where(requester_user_id: Current.user.id, status: "resulted"), :author) do
        denied_scope.order(status_changed_at: :desc).limit(PAGE)
      end
    end

    # A46: o contador do Início. Só números; nada de dado clínico e nenhum
    # clinical_record.viewed (ninguém leu prontuário). A lista completa, com
    # trilha, só quando a tela de ciência abre.
    def pending_count
      return forbid("missing_role") unless Current.user.has_role?("health_professional")

      pending = ExamOrder.where(requester_user_id: Current.user.id, status: "resulted").count
      render json: { pending: pending, has_more: pending > PAGE, denied: [ denied_scope.count, PAGE ].min }
    end

    def team
      units = Exams::Access.team_unit_ids(Current.user)
      return forbid("not_in_team") if units.empty?

      list(ExamOrder.where(unit_id: units, status: "resulted").where.not(escalated_at: nil), :team)
    end

    private

    def denied_scope
      ExamOrder.where(requester_user_id: Current.user.id, status: "denied").where("status_changed_at >= ?", DENIED_WINDOW.ago)
    end

    def list(scope, kind)
      page = Exams::OrderQuery.call(scope, params)
      grant = Exams::Access::Grant.new(view: :clinical, kind: kind, opening: nil)
      page[:orders].each { |order| Exams::Trail.viewed!(order: order, user: Current.user, grant: grant) }
      body = { orders: page[:orders].map { |o| Exams::Json.order(o, view: :clinical, user: Current.user, events: false) },
               next_before: page[:next_before] }
      if block_given?
        denied = yield.includes(:patient, :unit, :exam_provider, :requester_user, :consultation_exam_request, :events).to_a
        denied.each { |order| Exams::Trail.viewed!(order: order, user: Current.user, grant: grant) }
        body[:denied] = denied.map { |o| Exams::Json.order(o, view: :clinical, user: Current.user, events: false, denied_reason: true) }
      end
      render json: body
    rescue Exams::Cursor::Invalid
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    rescue Exams::OrderQuery::InvalidFilter
      render json: { error: "invalid_filter" }, status: :unprocessable_entity
    end
  end
end
