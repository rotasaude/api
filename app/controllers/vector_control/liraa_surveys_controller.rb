# /vector_control/liraa_surveys (módulo 35a, ADR 0054; contrato §7, §12; Q8,
# Q9): o LIRAa da coordenação (403 missing_role para os outros).
#   - GET /liraa_surveys → `{ items }` de LiraaSurvey, mais recente primeiro.
#     Q31: também para quem lê o relatório liraa (o filtro survey_id: o
#     municipal_admin e o vector_lab), pela regra dele (Access.reads_report?);
#   - POST /liraa_surveys e PATCH /liraa_surveys/:id → LiraaSurvey
#     (Liraa::SaveSurvey; fora do rascunho → 409 survey_not_draft). Q37(2):
#     o PATCH leva expected_version (a version lida): ausente → 422
#     expected_version_required, fora de inteiro >= 0 → 422 invalid_request,
#     divergente → 409 survey_changed; o POST não a aceita;
#   - POST /liraa_surveys/:id/draw (step-up; Liraa::Draw) e /close (step-up;
#     Liraa::Close; fora de drawn → 409 invalid_transition path status) →
#     LiraaSurvey;
#   - GET /liraa_surveys/:id/items?before= → `{ items, next_before }` de
#     LiraaItem na ordem do sorteio (substitutos no fim). O endereço curto do
#     24a: grava a trilha territory_registry por microárea
#     (TerritoryRegistry::Trail.households_listed!). Nunca morador.
module VectorControl
  class LiraaSurveysController < BaseController
    LIMIT = 100

    before_action(only: %i[create update draw close]) { query_only! }
    # A query antes de ler o levantamento (Task 17).
    before_action(only: :items) { query_only!(:before) }
    before_action :coordinator!, except: :index
    before_action(only: :index) { report_reader!("liraa") }
    before_action :require_step_up!, only: %i[draw close]
    before_action :load_survey, only: %i[update draw close items]

    def index
      return unless query_only!

      render json: { items: Json.liraa_surveys(LiraaSurvey.order(created_at: :desc, id: :desc).to_a) }
    end

    def create
      result = Liraa::SaveSurvey.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.liraa_survey(result.payload[:survey]), status: :created
    end

    def update
      result = Liraa::SaveSurvey.call(params: body, by: Current.user, survey: @survey)
      return render_failure(result) if result.failure?

      render json: Json.liraa_survey(result.payload[:survey])
    end

    def draw
      return render_refusal("invalid_request", path: body.keys.first) if body.any?

      result = Liraa::Draw.call(survey: @survey, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.liraa_survey(result.payload[:survey])
    end

    def close
      return render_refusal("invalid_request", path: body.keys.first) if body.any?

      result = Liraa::Close.call(survey: @survey, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.liraa_survey(result.payload[:survey])
    end

    def items
      position = cursor
      return if performed?

      scope = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: @survey.id })
      if position
        scope = scope.where("(liraa_draw_items.created_at, liraa_draw_items.id) > (?, ?)", position.at, position.id)
      end
      rows = scope.order("liraa_draw_items.created_at", "liraa_draw_items.id").limit(LIMIT + 1).to_a
      shown = rows.first(LIMIT)
      next_before = rows.size > LIMIT ? CareLines::Cursor.encode(shown.last.created_at, shown.last.id) : nil
      trail!(shown)
      render json: { items: Json.liraa_items(shown), next_before: next_before }
    end

    private

    def load_survey
      @survey = uuid?(params[:id]) ? LiraaSurvey.find_by(id: params[:id]) : nil
      not_found unless @survey
    end

    def trail!(items)
      ids = items.map(&:household_id).uniq
      areas = Household.where(id: ids).pluck(:id, :micro_area_id).to_h
      ids.group_by { |id| areas.fetch(id) }.each do |micro_area_id, household_ids|
        TerritoryRegistry::Trail.households_listed!(user: Current.user, micro_area_id: micro_area_id, household_ids: household_ids)
      end
    end
  end
end
