# A fila do regulador (contrato §4, §13 G2, G6; papel `care_regulator`):
#   GET /regulation/requests        a fila, com cursor (uma trilha por requisição)
#   GET /regulation/requests/count  contadores (sem trilha)
#   GET /regulation/requests/:id    o detalhe com o andamento (trilha por pessoa)
# Escopo: a cidade toda. Municipal_admin e health_professional não leem a fila.
# Filtros e cursor só da query (o `target_code` é o único alvo em URL e não leva
# paciente); dado do paciente só no corpo JSON da resposta.
module CareRegulation
  class RequestsController < BaseController
    QUEUE_PARAMS = (Queue::FILTERS + %w[before limit]).freeze

    before_action { forbid unless regulator? }

    def index
      unknown = request.query_parameters.keys.find { |key| QUEUE_PARAMS.exclude?(key) }
      return render(json: { error: "invalid_request", path: unknown }, status: :unprocessable_entity) if unknown

      limit = page_limit
      return unless limit

      query = request.query_parameters
      today = Time.zone.today
      page = Queue.page(filters: query.slice(*Queue::FILTERS), before: query["before"], limit: limit, today: today)
      rows = page.fetch(:rows)
      Trail.listed!(user: Current.user, regulation_request_ids: rows.map(&:id)) if rows.any?
      render json: { requests: rows.map { |r| Json.request(r, events: false, today: today) }, next_before: page.fetch(:next_before) }
    rescue Queue::InvalidFilter => e
      render json: { error: "invalid_request", path: e.field }, status: :unprocessable_entity
    rescue Cursor::Invalid
      render_error("invalid_cursor")
    end

    def count
      render json: Queue.counts(today: Time.zone.today)
    end

    def show
      found = uuid?(params[:id]) &&
              RegulationRequest.where(status: Catalog::QUEUE_STATUSES)
                               .preload(Queue::PRELOAD, events: { by_user: :professional }).find_by(id: params[:id])
      return not_found unless found

      Trail.person_viewed!(user: Current.user, patient_id: found.patient_id)
      render json: Json.request(found, events: true, today: Time.zone.today)
    end
  end
end
