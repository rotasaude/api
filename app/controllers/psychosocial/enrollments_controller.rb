# Matrículas do CAPS (ADR 0049; contrato §4, P5, P13):
#   GET   /psychosocial/enrollments?health_unit_id&status&before
#         lista do CAPS lotado, sem CID, substância, origem nem ESF, sem trilha;
#         sem `q` (P5: o dashboard filtra localmente; `q` → 422)
#   POST  /psychosocial/enrollments            → 201 <detalhe>, sem trilha (quem cria digitou)
#   GET   /psychosocial/enrollments/:id        <detalhe> com trilha (`resource: "enrollment"`)
#   PATCH /psychosocial/enrollments/:id        → <detalhe> com trilha (ruling); corpo vazio → 422
#   POST  /psychosocial/enrollments/:id/close  { destination, closed_on } → <detalhe> com trilha
# Matrícula de outro CAPS (ou de CAPS onde quem pede não está lotado) → 404.
# Lista do mais nova para a mais antiga (created_at, id), em páginas de PAGE,
# com `next_before`. Dado do paciente só no corpo; ids na URL.
module Psychosocial
  class EnrollmentsController < BaseController
    PAGE = 500
    STATUSES = %w[open closed].freeze
    CLOSE_KEYS = %w[destination closed_on].freeze

    before_action :load_enrollment, only: %i[show update close]

    def index
      return unless query_only!("health_unit_id", "status", "before")

      query = request.query_parameters
      unit = staff_unit!(query["health_unit_id"])
      return unless unit

      status = query["status"]
      return render_refusal("status") if status && !STATUSES.include?(status)

      scope = PsychosocialEnrollment.where(health_unit_id: unit.id)
      scope = scope.open_enrollments if status == "open"
      scope = scope.where.not(closed_on: nil) if status == "closed"
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(psychosocial_enrollments.created_at, psychosocial_enrollments.id) < (?, ?)", at, id)
      end
      rows = scope.includes(:patient, reference_user: :professional).order(created_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      cbos = Access.cbos(page.map(&:reference_user_id), unit.id)
      reviews = review_dates(page.map(&:id))
      render json: { items: page.map { |e| Json.enrollment_item(e, cbos: cbos, review_on: reviews[e.id]) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.created_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def show = render_viewed(@enrollment)

    def create
      return unless query_only!

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      result = CreateEnrollment.call(attrs: body, unit: unit, by: Current.user)
      return render_failure(result) if result.failure?

      render json: detail(result.payload.fetch(:enrollment)), status: :created
    end

    def update
      result = UpdateEnrollment.call(enrollment: @enrollment, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render_viewed(result.payload.fetch(:enrollment))
    end

    def close
      unknown = (body.keys - CLOSE_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      result = CloseEnrollment.call(enrollment: @enrollment, destination: body_param("destination"), closed_on: body_param("closed_on"),
                                    by: Current.user)
      return render_failure(result) if result.failure?

      render_viewed(result.payload.fetch(:enrollment))
    end

    private

    # O detalhe clínico com a trilha (GET, e as respostas do PATCH e do close: ruling).
    def render_viewed(enrollment)
      Trail.viewed!(patient: enrollment.patient_id, user: Current.user, resource: "enrollment")
      render json: detail(enrollment)
    end

    def detail(enrollment)
      Json.enrollment(enrollment, cbos: Access.cbos([ enrollment.reference_user_id ], enrollment.health_unit_id),
                                  review_on: review_dates([ enrollment.id ])[enrollment.id])
    end

    # { enrollment_id => review_on do PTS vigente (a versão mais nova) }.
    def review_dates(ids)
      return {} if ids.empty?

      CarePlanReview.latest(PsychosocialEnrollment.where(id: ids)).transform_values { |plan| plan[:review_on] }
    end
  end
end
