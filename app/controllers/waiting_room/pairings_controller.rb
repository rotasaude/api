# POST /waiting_room/pair {code} → 201 { display_token } (ADR 0050; contrato
# §8 e §14 Q8; Valor fixado 6). Sem sessão e sem CSRF: a TV não tem login. O
# corpo é JSON (415 json_required, como toda escrita do dashboard). Ordem:
# limite de 10/min por IP → interruptor → código. O token em claro só sai
# nesta resposta, sem cache.
module WaitingRoom
  class PairingsController < BaseController
    rate_limit to: 10, within: 1.minute, name: "waiting_room_pair", store: RateLimitStore,
               by: -> { request.remote_ip }, with: -> { too_many_requests }
    before_action :require_waiting_room!

    def create
      return render(json: { error: "json_required" }, status: :unsupported_media_type) unless request.media_type == "application/json"

      result = Pair.call(code: body["code"])
      return render_failure(result) if result.failure?

      response.headers["Cache-Control"] = "no-store"
      render json: { display_token: result.payload.fetch(:display_token) }, status: :created
    end
  end
end
