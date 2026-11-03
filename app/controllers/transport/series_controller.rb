# Séries recorrentes da central (contrato §4; §14 T6): GET /transport/series
# (`{ items }`), GET/PATCH /transport/series/:id, POST /transport/series (201)
# e POST /transport/series/:id/suspend `{ from_on, reason }`. Sempre a forma
# <series>. Só a central; id desconhecido → 404. Dado do paciente e do
# acompanhante só no corpo.
module Transport
  class SeriesController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }
    before_action :load_series, only: %i[show update suspend]

    def index
      return unless query_only!

      series = TransportSeries.includes(:patient, :transport_destination).order(:created_at, :id)
      render json: { items: series.map { |s| Json.series(s) } }
    end

    def show
      return unless query_only!

      render json: Json.series(@series)
    end

    def create
      return unless query_only!

      respond(SaveSeries.call(attrs: body, by: Current.user), status: :created)
    end

    def update
      return unless query_only!

      respond(SaveSeries.call(attrs: body, by: Current.user, series: @series))
    end

    def suspend
      return unless query_only!

      respond(SuspendSeries.call(series: @series, from_on: body_param("from_on"), reason: body_param("reason"), by: Current.user))
    end

    private

    def load_series
      @series = uuid?(params[:id]) ? TransportSeries.find_by(id: params[:id]) : nil
      not_found unless @series
    end

    def respond(result, status: :ok)
      return render_failure(result) if result.failure?

      render json: Json.series(result.payload.fetch(:series)), status: status
    end
  end
end
