# /vector_control/cycles (módulo 35a, ADR 0054; contrato §5, §12; Q8, D-6):
# ciclos de trabalho da coordenação (403 missing_role para os outros).
#   - GET /cycles?year= → `{ items }` de VectorCycle, por (ano, número);
#   - POST /cycles e PATCH /cycles/:id → VectorCycle (VectorControl::SaveCycle);
#   - GET /cycles/:id → CycleSummary: o ciclo e, por bairro ativo (por nome),
#     os números do VectorControl::CycleStats. Só contagens: sem trilha.
module VectorControl
  class CyclesController < BaseController
    YEAR = /\A\d{4}\z/

    # A query antes de ler o ciclo (Task 17): id que não existe com query também é 422.
    before_action(only: %i[show create update]) { query_only! }
    before_action :coordinator!
    before_action :load_cycle, only: %i[show update]

    def index
      return unless query_only!(:year)

      year = request.query_parameters["year"]
      return render_refusal("invalid_request", path: "year") unless year.nil? || (year.is_a?(String) && year.match?(YEAR))

      cycles = VectorCycle.order(:year, :number)
      cycles = cycles.where(year: Integer(year, 10)) if year
      render json: { items: cycles.map { |cycle| Json.cycle(cycle) } }
    end

    def show
      render json: Json.cycle_summary(@cycle, Neighborhood.active_neighborhoods.order(:name, :id).to_a)
    end

    def create
      result = SaveCycle.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.cycle(result.payload[:cycle]), status: :created
    end

    def update
      result = SaveCycle.call(params: body, by: Current.user, cycle: @cycle)
      return render_failure(result) if result.failure?

      render json: Json.cycle(result.payload[:cycle])
    end

    private

    def load_cycle
      @cycle = uuid?(params[:id]) ? VectorCycle.find_by(id: params[:id]) : nil
      not_found unless @cycle
    end
  end
end
