# Frascos multidose da sala (contrato §3; §15 V14; dashboard D7):
#   POST /vaccination/rooms/:room_id/vials          { lot_id }  → 201 <vial>
#   GET  /vaccination/rooms/:room_id/vials?status=  → { vials: [<vial>] }
#   POST /vaccination/vials/:id/close_out           { reason }  → 200 <vial>
# Abrir e listar: vacinador ou responsável da sala. Descartar: só `room_lead`
# (403 room_lead_required). Sem dado de paciente e sem trilha.
module Vaccination
  class VialsController < BaseController
    LIST_LIMIT = 200

    def create
      room = member_room or return
      return unless query_only!

      lot_id = body_param("lot_id")
      return render_refusal("lot_id") unless uuid?(lot_id)

      result = OpenVial.call(room: room, lot: StockLot.find_by(id: lot_id), by: Current.user)
      return render_vial_failure(result) if result.failure?

      render json: Json.vial(result.payload[:vial], now: Time.current), status: :created
    end

    def index
      room = member_room or return
      return unless query_only!(:status)

      status = params[:status]
      return render_refusal("status") unless status.nil? || Catalog::VIAL_STATUSES.include?(status)

      now = Time.current
      scope = room.vial_openings.includes(:stock_lot).order(opened_at: :desc, id: :asc).limit(LIST_LIMIT)
      render json: { vials: Json.vials(filter(scope, status, now), now: now) }
    end

    def close_out
      return unless query_only!

      vial = uuid?(params[:id]) ? VialOpening.includes(:vaccine_room, :stock_lot).find_by(id: params[:id]) : nil
      return not_found unless vial

      roles = Access.room_roles(user: Current.user, room: vial.vaccine_room)
      return forbid if roles.empty?
      return forbid("room_lead_required") unless roles.include?("room_lead")

      result = CloseOutVial.call(vial: vial, reason: body_param("reason"), by: Current.user)
      if result.failure?
        return result.reason == :invalid_reason ? render_refusal("reason", "invalid_reason") : render_failure(result)
      end

      render json: Json.vial(result.payload[:vial], now: Time.current)
    end

    private

    # Aberto: sem fechamento e não vencido. Vencido: o job fechou sem autor, ou
    # venceu e o job ainda não passou. Descartado: fechado por alguém.
    def filter(scope, status, now)
      case status
      when "open" then scope.where(closed_at: nil).where("expires_at > ?", now)
      when "expired" then scope.where(closed_by_user_id: nil).where("closed_at IS NOT NULL OR expires_at <= ?", now)
      when "closed_out" then scope.where.not(closed_by_user_id: nil)
      else scope
      end
    end

    def render_vial_failure(result)
      return render_error(:lot_not_in_room, :not_found) if result.reason == :lot_not_in_room

      render_refusal("lot_id", result.reason)
    end
  end
end
