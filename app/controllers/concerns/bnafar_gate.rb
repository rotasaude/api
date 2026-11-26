# Rotas do envio ao SI-BNAFAR (módulo 27b). Dois níveis (Q40):
#   - `require_bnafar_enabled!`: o interruptor `bnafar` LIGADO, utilizável ou
#     não (situação e remessas: o dashboard mostra a faixa justamente com a
#     credencial recusada);
#   - `require_bnafar!`: o `bnafar` UTILIZÁVEL (reenvio e correção, que enviam).
# Desligado (ou inutilizável, no segundo) → 403 feature_disabled.
module BnafarGate
  private

  def require_bnafar_enabled!
    return if Bnafar::Gate.enabled?(Current.city)

    render_bnafar_disabled
  end

  def require_bnafar!
    return if Bnafar::Gate.usable?(Current.city)

    render_bnafar_disabled
  end

  def render_bnafar_disabled = render(json: { error: "feature_disabled", feature: Bnafar::Gate::KEY }, status: :forbidden)
end
