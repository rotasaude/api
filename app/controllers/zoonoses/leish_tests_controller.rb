# /zoonoses/leish_tests (módulo 35b, ADR 0054; contrato §6, §10, §16): a
# coleta e a sorologia canina, para team? (403 missing_role).
#   - POST /leish_tests (Zoonoses::RecordLeishTest, origin "dashboard") → 201
#     com a coleta e a etiqueta;
#   - PATCH /leish_tests/:id com expected_version (a correção dos resultados)
#     → a coleta;
#   - GET /leish_tests?survey_id=&pending=elisa|outcome&before=&limit= →
#     `{ items, next_before }`, mais recente primeiro pela criação (50 por
#     página, até 100). pending=elisa: DPP reagente sem ELISA; pending=outcome:
#     DPP e ELISA reagentes sem desfecho. O animal só com `has_tutor`, nunca o
#     tutor.
# A escrita recusa query (422 invalid_request); a lista recusa chave fora dos
# filtros.
module Zoonoses
  class LeishTestsController < BaseController
    FILTERS = %i[survey_id pending before limit].freeze
    PENDING = %w[elisa outcome].freeze

    before_action :team!
    before_action(only: %i[create update]) { query_only! }

    def index
      return unless query_only!(*FILTERS)

      scope = filtered
      return if performed?

      limit = page_limit
      return unless limit

      position = CareLines::Cursor.decode(request.query_parameters["before"])
      rows, next_before = page(scope, :created_at, limit: limit, position: position)
      render json: { items: rows.map { Json.leish_test_record(_1) }, next_before: next_before }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end

    def create
      result = RecordLeishTest.call(params: body, by: Current.user, origin: "dashboard")
      return render_failure(result) if result.failure?

      render json: Json.leish_test_record(result.payload.fetch(:test)), status: :created
    end

    def update
      test = uuid?(params[:id]) ? LeishTest.find_by(id: params[:id]) : nil
      return not_found unless test

      result = RecordLeishTest.call(params: body, by: Current.user, test: test)
      return render_failure(result) if result.failure?

      render json: Json.leish_test_record(result.payload.fetch(:test))
    end

    private

    # O escopo dos filtros; recusado, já respondeu 422 (performed?).
    def filtered
      survey_id = query_uuid("survey_id")
      return if performed?

      pending = request.query_parameters["pending"]
      return render_refusal("invalid_request", path: "pending") if pending && !PENDING.include?(pending)

      scope = LeishTest.includes(:animal, :outcome)
      scope = scope.where(leish_survey_id: survey_id) if survey_id
      case pending
      when "elisa" then scope.where(dpp_result: "reactive", elisa_result: nil)
      when "outcome"
        scope.where(dpp_result: "reactive", elisa_result: "reactive").where.not(id: LeishDogOutcome.select(:leish_test_id))
      else scope
      end
    end
  end
end
