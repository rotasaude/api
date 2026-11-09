# Rotas do painel de chamada: interruptor desligado → 403 feature_disabled.
module WaitingRoomGate
  private

  def require_waiting_room!
    return if WaitingRoom::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: WaitingRoom::Gate::KEY }, status: :forbidden
  end
end
