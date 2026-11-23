# Rotas da vigilância ambiental (ADR 0054): interruptor desligado ou sem a
# visita domiciliar utilizável → 403 feature_disabled. O controller declara
# `before_action :require_vector_control!`. As peças do 35a que o centro de
# zoonoses usa (módulo 35b, Q11: produtos, local de estoque, faltas,
# quarteirões, domínios) trocam pelo `require_vector_supplies!`, que abre com
# o vector_control OU o zoonoses utilizável (VectorControl::Gate.supplies_usable?);
# a recusa nomeia o `vector_control`, a família de rotas.
module VectorControlGate
  private

  def require_vector_control!
    return if VectorControl::Gate.usable?(Current.city)

    render_vector_feature_disabled
  end

  def require_vector_supplies!
    return if VectorControl::Gate.supplies_usable?(Current.city)

    render_vector_feature_disabled
  end

  def render_vector_feature_disabled
    render json: { error: "feature_disabled", feature: VectorControl::Gate::KEY }, status: :forbidden
  end
end
