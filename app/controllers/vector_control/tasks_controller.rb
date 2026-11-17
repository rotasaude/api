# /vector_control/tasks (módulo 35a, ADR 0054; contrato §6, §8, §12; Q8, Q9):
# as tarefas da coordenação (403 missing_role para os outros).
#   - GET /tasks?state=open|closed&before= (padrão open; closed = done ou
#     dismissed): `{ items, next_before }` de VectorTask, mais recente
#     primeiro;
#   - POST /tasks/:id/close `{ state, note }` (VectorControl::CloseTask) →
#     VectorTask; fora de open → 409 invalid_transition path status.
# Nunca paciente: o caso sai só como doença e data. A nota nunca sai.
module VectorControl
  class TasksController < BaseController
    STATES = %w[open closed].freeze
    LIMIT = 50

    before_action(only: :close) { query_only! }
    before_action :coordinator!

    def index
      return unless query_only!(:state, :before)

      state = request.query_parameters.fetch("state", "open")
      return render_refusal("invalid_request", path: "state") unless STATES.include?(state)

      position = cursor
      return if performed?

      scope = state == "open" ? VectorTask.open_tasks : VectorTask.where.not(state: "open")
      rows, next_before = page(scope, :created_at, limit: LIMIT, position: position)
      render json: { items: Json.tasks(rows), next_before: next_before }
    end

    def close
      task = VectorTask.find_by(id: params[:id])
      return not_found unless task

      unknown = (body.keys - %w[state note]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = CloseTask.call(task: task, state: body_param("state"), note: body_param("note"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.tasks([ result.payload[:task] ]).sole
    end
  end
end
