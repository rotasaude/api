# Filtros e página das listas de exame (contrato §3; F-21.5 usa overdue/stage).
module Exams
  module OrderQuery
    class InvalidFilter < StandardError; end

    module_function

    def call(scope, params, today: Time.zone.today)
      scope = filter(scope, params, today)
      at, id = Cursor.decode(params[:before])
      scope = scope.where("(exam_orders.created_at, exam_orders.id) < (?, ?)", at, id) if at
      limit = Timeline::Query.limit(params[:limit])
      rows = scope.includes(:patient, :unit, :exam_provider, :requester_user, :consultation_exam_request, result: :pdf_file)
                  .order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      { orders: page, next_before: rows.size > limit ? Cursor.encode(page.last) : nil }
    end

    def filter(scope, params, today)
      statuses = params[:status]
      if statuses.present?
        raise InvalidFilter unless statuses.is_a?(Array) && (statuses - ExamOrder::STATUSES).empty?

        scope = scope.where(status: statuses)
      end
      if params[:stage].present?
        raise InvalidFilter unless Deadlines::STAGES.include?(params[:stage])

        scope = scope.where(stage: params[:stage])
      end
      scope = scope.where(status: ExamOrder::OPEN_STATUSES).where("exam_orders.stage_due_on < ?", today) if params[:overdue] == "true"
      if params[:provider_id].present?
        raise InvalidFilter unless params[:provider_id].to_s.match?(BaseController::UUID)

        scope = scope.where(exam_provider_id: params[:provider_id])
      end
      if params[:sigtap_code].present?
        raise InvalidFilter unless params[:sigtap_code].to_s.match?(/\A02\d{8}\z/)

        scope = scope.where(sigtap_code: params[:sigtap_code])
      end
      scope
    end
    private_class_method :filter
  end
end
