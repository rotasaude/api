# Guarda de query das rotas do módulo 24b fora do BaseController da visita
# (/field/v1 e /field_devices): só as chaves que a ação de fato lê; qualquer
# outra (cpf, texto, token) → 422 invalid_request, sem ecoar o valor enviado.
# Mesmo contrato do `query_only!` de HomeVisits::BaseController.
module StrictQuery
  private

  def query_only!(*allowed)
    return true if (request.query_parameters.keys - allowed.map(&:to_s)).empty?

    render json: { error: "invalid_request" }, status: :unprocessable_entity
    false
  end
end
