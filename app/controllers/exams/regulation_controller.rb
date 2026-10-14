# Fila de regulação (ADR 0036; contrato §4): exam_regulator ou municipal_admin.
# Sempre a visão administrativa (A32: o motivo de negar/cancelar aparece nela).
module Exams
  class RegulationController < BaseController
    RANK = Arel.sql("CASE exam_orders.priority WHEN 'urgent' THEN 0 ELSE 1 END")

    before_action { forbid("missing_role") unless Exams::Access.regulator?(Current.user) }
    before_action :load_order, only: %i[authorize deny]

    def queue
      scope = ExamOrder.where(status: "awaiting_authorization")
      if (cursor = decode(params[:before]))
        scope = scope.where("(#{RANK}, exam_orders.created_at, exam_orders.id) > (?, ?, ?)", *cursor)
      end
      limit = limit_param
      rows = scope.includes(:patient, :unit, :requester_user, :exam_provider, :consultation_exam_request)
                  .order(RANK, :created_at, :id).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { orders: page.map { |o| Exams::Json.order(o, view: :administrative, user: Current.user, events: false) },
                     next_before: rows.size > limit ? encode(page.last) : nil }
    rescue ArgumentError
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end

    def authorize
      provider = params[:provider_id].is_a?(String) && ExamProvider.find_by(id: params[:provider_id], active: true)
      return render_failure(Result.fail(:provider_not_enabled_for_exam)) unless provider && Exams::Steps.enabled?(provider, @order)
      # A34: o laboratório simulado só recebe com fake_lab utilizável (como em Steps.schedule).
      return render_failure(Result.fail(:provider_not_enabled_for_exam)) if provider.simulated && !Exams::Gate.fake_lab_usable?(Current.city)

      respond(step("authorized", changes: { exam_provider_id: provider.id }))
    end

    def deny = respond(step("denied", reason: params[:reason]))

    private

    # Trava o pedido antes da transição: autorizar e negar concorrentes → um vence, o outro 409.
    def step(kind, **opts)
      ApplicationRecord.transaction do
        @order.lock!
        Exams::Transition.call(order: @order, kind: kind, actor_user: Current.user, **opts)
      end
    end

    def respond(result)
      return render_failure(result) if result.failure?

      render json: Exams::Json.order(@order.reload, view: :administrative, user: Current.user)
    end

    def load_order
      @order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      not_found unless @order
    end

    def encode(order)
      rank = order.priority == "urgent" ? 0 : 1
      Base64.urlsafe_encode64("#{rank}|#{order.created_at.utc.iso8601(6)}|#{order.id}", padding: false)
    end

    def decode(raw)
      return nil if raw.blank?
      raise ArgumentError unless raw.is_a?(String)

      rank, at, id = Base64.urlsafe_decode64(raw).split("|", 3)
      raise ArgumentError unless %w[0 1].include?(rank) && id.to_s.match?(UUID)

      [ rank.to_i, Time.iso8601(at), id ]
    end
  end
end
