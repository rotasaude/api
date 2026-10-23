# Rotas do cadastro territorial (ADR 0042; contrato §1): interruptor desligado
# ou sem o prontuário utilizável → 403 feature_disabled. O controller declara
# o `before_action :require_territory_registry!` (como CareLinesGate).
module TerritoryRegistryGate
  private

  def require_territory_registry!
    return if TerritoryRegistry::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: TerritoryRegistry::Gate::KEY }, status: :forbidden
  end
end
