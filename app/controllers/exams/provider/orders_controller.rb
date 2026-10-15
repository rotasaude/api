# Portal do prestador (ADR 0036; contrato §6): só as guias do prestador do
# usuário (isolamento no servidor; 404 para a de outro). Nunca prontuário.
# A35: todo passo grava o prestador E o funcionário (actor_provider + actor_user).
module Exams
  module Provider
    class OrdersController < Exams::BaseController
      VISIBLE = %w[awaiting_schedule scheduled collected resulted acknowledged].freeze

      before_action :load_provider
      before_action :provider_order!, except: :index

      def index
        scope = ExamOrder.where(exam_provider_id: @provider.id, status: VISIBLE)
        page = Exams::OrderQuery.call(scope, params)
        overdue = scope.where(status: ExamOrder::OPEN_STATUSES).where("stage_due_on < ?", Time.zone.today).count
        response.headers["X-Overdue-Count"] = overdue.to_s
        render json: { orders: page[:orders].map { |o| Exams::Json.provider_order(o) }, next_before: page[:next_before],
                       overdue_count: overdue }
      rescue Exams::OrderQuery::InvalidFilter
        render json: { error: "invalid_filter" }, status: :unprocessable_entity
      rescue Exams::Cursor::Invalid
        render json: { error: "invalid_cursor" }, status: :unprocessable_entity
      end

      def schedule
        respond(Exams::Steps.schedule(order: @order, actor_provider: @provider, actor_user: Current.user,
                                      params: { scheduled_at: params[:scheduled_at], scheduled_place: params[:scheduled_place] }))
      end

      def collect = respond(Exams::Steps.collect(order: @order, actor_provider: @provider, actor_user: Current.user))

      # Contrato §6/A17: mesmo corpo do §3. A35: prestador E funcionário na trilha
      # (a unidade vê só o prestador como ator).
      def result
        # Contrato §9/B12: resultado do laboratório municipal só pela liberação.
        return render(json: { error: "provider_uses_municipal_lab" }, status: :unprocessable_entity) if @provider.uses_municipal_lab

        respond(Exams::RegisterResult.call(order: @order, source: "provider", file_id: params[:upload_id],
                                           released_on: params[:released_on], laboratory_name: params[:laboratory_name],
                                           critical: params[:critical], values: params[:values], by_user: Current.user,
                                           by_provider: @provider))
      end

      private

      def load_provider
        @provider = Exams::Access.provider_of(Current.user)
        return forbid("missing_role") unless @provider

        # A15: o portal do prestador simulado só existe com fake_lab utilizável.
        return unless @provider.simulated && !Exams::Gate.fake_lab_usable?(Current.city)

        render json: { error: "feature_disabled", feature: Exams::Gate::FAKE_LAB_KEY }, status: :forbidden
      end

      def provider_order!
        @order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id], exam_provider_id: @provider.id)
        not_found unless @order
      end

      def respond(result)
        return render_failure(result) if result.failure?

        render json: Exams::Json.provider_order(@order.reload)
      end
    end
  end
end
