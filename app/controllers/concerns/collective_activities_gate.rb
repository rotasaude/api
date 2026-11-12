# Rotas da atividade coletiva (ADR 0052): interruptor desligado ou sem o
# prontuário utilizável → 403 feature_disabled. O controller declara
# `before_action :require_collective_activities!`.
module CollectiveActivitiesGate
  private

  def require_collective_activities!
    return if CollectiveActivities::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: CollectiveActivities::Gate::KEY }, status: :forbidden
  end
end
