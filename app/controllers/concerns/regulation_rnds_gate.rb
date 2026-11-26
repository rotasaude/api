# Rotas do envio da regulação à RNDS (módulo 26c). Dois níveis (Q10):
#   - `require_rnds_regulation_enabled!`: o interruptor LIGADO, utilizável ou
#     não (situação e lista: a tela abre com a credencial recusada);
#   - `require_rnds_regulation!`: o interruptor UTILIZÁVEL (reenvio e o que envia).
# Desligado (ou inutilizável, no segundo) → 403 feature_disabled.
module RegulationRndsGate
  private

  def require_rnds_regulation_enabled!
    return if Regulation::RndsGate.enabled?(Current.city)

    render_rnds_regulation_disabled
  end

  def require_rnds_regulation!
    return if Regulation::RndsGate.usable?(Current.city)

    render_rnds_regulation_disabled
  end

  def render_rnds_regulation_disabled
    render json: { error: "feature_disabled", feature: Regulation::RndsGate::KEY }, status: :forbidden
  end
end
