# Devolvidos da unidade solicitante (contrato §5, §13 G6; plano do api, Desvio
# 13):
#   GET /regulation/returned?unit_id=&before=&limit=
# `health_professional` com vínculo ativo na unidade e CBO que pede regulação
# (225*, 2235*, 2232*; senão 403 missing_role). Os itens vêm com `events` (o
# motivo da devolução está no evento `returned`), paginados por cursor opaco
# (ordem requested_at, id; limit 1..100, padrão 50: invalid_limit; before
# inválido: invalid_cursor) com `next_before` (nulo no fim), e cada página grava
# UMA trilha de lista (só os ids dos pedidos da página). Na URL só a unidade e
# a paginação.
module CareRegulation
  class ReturnedController < BaseController
    before_action { forbid unless Current.user.has_role?("health_professional") }

    def index
      return unless query_only!("unit_id", "before", "limit")

      unit_id = params[:unit_id]
      return render(json: { error: "invalid_request", path: "unit_id" }, status: :unprocessable_entity) unless uuid?(unit_id)
      return forbid unless requester_in?(unit_id)

      limit = page_limit
      return unless limit

      scope = RegulationRequest.where(status: "returned", requester_unit_id: unit_id)
      before = request.query_parameters["before"]
      if before.present?
        requested_at, id = Cursor.decode_page(before)
        scope = scope.where("(regulation_requests.requested_at, regulation_requests.id) > (?::timestamptz, ?::uuid)", requested_at.utc.iso8601(6), id)
      end
      fetched = scope.order(:requested_at, :id).limit(limit + 1).preload(Queue::PRELOAD, events: { by_user: :professional }).to_a
      rows = fetched.first(limit)
      next_before = Cursor.encode_page(rows.last.requested_at, rows.last.id) if fetched.size > limit
      Trail.listed!(user: Current.user, regulation_request_ids: rows.map(&:id)) if rows.any?
      today = Time.zone.today
      render json: { requests: rows.map { |r| Json.request(r, events: true, today: today) }, next_before: next_before }
    rescue Cursor::Invalid
      render_error("invalid_cursor")
    end

    private

    def requester_in?(unit_id)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: Current.user.id }, health_unit_id: unit_id)
                      .pluck(:cbo_code).any? { |cbo| Requesters.kind(cbo) }
    end
  end
end
