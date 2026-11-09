# GET /waiting_room/board com o cabeçalho X-Display-Token (ADR 0050; contrato
# §8 e §14 Q8; Valor fixado 6; preflight C-16). Sem cookie de sessão. Ordem
# (a do Hl7::BaseController): limite de 30/min pelo digest do token (ou pelo
# IP, sem token) → interruptor (403 feature_disabled) → token (ausente ou
# desconhecido 401 invalid_token; revogado ou TV desativada 401
# display_revoked). Sem trilha e sem evento: só `last_seen_at`, gravado por
# update_column (sem updated_at) quando vazio ou com mais de 60 s.
module WaitingRoom
  class BoardsController < BaseController
    SEEN_EVERY = 60.seconds

    rate_limit to: 30, within: 1.minute, name: "waiting_room_board", store: RateLimitStore,
               by: -> { display_token ? WaitingRoomDisplay.digest(display_token) : request.remote_ip },
               with: -> { too_many_requests }
    before_action :require_waiting_room!

    def show
      display = WaitingRoomDisplay.by_token(display_token)
      return render(json: { error: "invalid_token" }, status: :unauthorized) unless display
      return render(json: { error: "display_revoked" }, status: :unauthorized) if display.revoked? || !display.active

      now = Time.current
      display.update_column(:last_seen_at, now) if display.last_seen_at.nil? || display.last_seen_at <= now - SEEN_EVERY
      response.headers["Cache-Control"] = "no-store"
      render json: Board.call(display: display, now: now)
    end

    private

    def display_token = request.headers["X-Display-Token"].presence
  end
end
