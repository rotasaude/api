# /zoonoses/leish_outcomes (módulo 35b, ADR 0054; contrato §6, §10, Q18): o
# desfecho do cão reagente, para team? (403 missing_role).
#   - POST /leish_outcomes (Zoonoses::RecordLeishOutcome) → 201 com o
#     desfecho, sem a nota.
# Recusa query (422 invalid_request, nada lido da URL).
module Zoonoses
  class LeishOutcomesController < BaseController
    before_action :team!
    before_action { query_only! }

    def create
      result = RecordLeishOutcome.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.leish_outcome(result.payload.fetch(:outcome)), status: :created
    end
  end
end
