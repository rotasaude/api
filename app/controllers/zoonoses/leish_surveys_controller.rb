# /zoonoses/leish_surveys (módulo 35b, ADR 0054; contrato §6, §10, Q8, Q18,
# Q21, Q28): o inquérito de leishmaniose. Leitura reader? (team? ou
# municipal_admin); escrita e sugestão só a coordenação (403 missing_role).
#   - GET /leish_surveys → `{ items }`, mais recente primeiro (início,
#     criação), sem os domicílios;
#   - GET /leish_surveys/:id → o detalhe: household_ids (Q21), a sugestão de
#     população (Q18) e a prevalência;
#   - POST /leish_surveys (Zoonoses::SaveSurvey) → 201 com o detalhe;
#   - PATCH /leish_surveys/:id com expected_version, só em draft → o detalhe;
#   - POST /leish_surveys/:id/open e /close `{ expected_version }` → o
#     detalhe (fora da etapa, 409 invalid_transition path status);
#   - POST /leish_surveys/suggest `{ kind, neighborhood_id,
#     center_city_block_id?, rings? }` → `{ city_block_ids,
#     dog_population_suggested, target_dogs, below_focus_min }`, sem gravar
#     (Q28).
# Toda rota recusa query (422 invalid_request, nada lido da URL).
module Zoonoses
  class LeishSurveysController < BaseController
    before_action :reader!, only: %i[index show]
    before_action :coordinator!, except: %i[index show]
    before_action { query_only! }
    before_action :load_survey, only: %i[show update open_survey close_survey]

    def index
      surveys = LeishSurvey.includes(:neighborhood).order(starts_on: :desc, created_at: :desc, id: :desc).to_a
      render json: { items: surveys.map { Json.leish_survey(_1) } }
    end

    def show
      render json: Json.leish_survey_detail(@survey)
    end

    def create
      result = SaveSurvey.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.leish_survey_detail(result.payload.fetch(:survey)), status: :created
    end

    def update
      respond(SaveSurvey.call(params: body, by: Current.user, survey: @survey))
    end

    def open_survey
      respond(SaveSurvey.transition(survey: @survey, params: body, by: Current.user, from: "draft", to: "open"))
    end

    def close_survey
      respond(SaveSurvey.transition(survey: @survey, params: body, by: Current.user, from: "open", to: "closed"))
    end

    def suggest
      result = SaveSurvey.suggest(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: result.payload.fetch(:suggestion)
    end

    private

    def load_survey
      @survey = uuid?(params[:id]) ? LeishSurvey.find_by(id: params[:id]) : nil
      not_found unless @survey
    end

    def respond(result)
      return render_failure(result) if result.failure?

      render json: Json.leish_survey_detail(result.payload.fetch(:survey))
    end
  end
end
