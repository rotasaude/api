# Faltas por paciente (contrato §4, T18): GET /transport/no_shows?from=&to=,
# só a central; até 366 dias. `{ items: [ { patient: { id, display_name }, count,
# dates } ] }`. Sem destino clínico, sem trilha.
module Transport
  class NoShowsController < BaseController
    MAX_DAYS = 366

    before_action { forbid unless Access.dispatcher?(Current.user) }

    def index
      return unless query_only!(:from, :to)

      from = Support.date(params[:from])
      to = Support.date(params[:to])
      return render_refusal("from") unless from
      return render_refusal("to") unless to && to >= from && (to - from).to_i < MAX_DAYS

      items = NoShows.call(from: from, to: to).map do |item|
        { "patient" => item[:patient].stringify_keys, "count" => item[:count], "dates" => item[:dates].map(&:iso8601) }
      end
      render json: { items: items }
    end
  end
end
