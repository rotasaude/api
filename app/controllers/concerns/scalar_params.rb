# Parâmetros escalares nos endpoints de escrita da cidade (fix final do Plano 2
# das assinaturas, I2). `params.require(:name)` aceita `{"name":["A","B"]}`: em
# RevertActivation isso misturava o histórico de dois protocolos e acabava num
# RecordNotUnique (500). Um valor que não é escalar — array ou hash — responde
# 400 { error: "bad_request" } antes de chegar ao command.
#
# Obrigatórios usam o `params.expect` do Rails 8, que já recusa array e hash
# levantando ActionController::ParameterMissing; opcionais usam
# `optional_scalar_param`, que levanta a mesma exceção. As duas caem no mesmo
# rescue_from — um só formato de 400, com ou sem o parâmetro.
module ScalarParams
  extend ActiveSupport::Concern

  included do
    rescue_from ActionController::ParameterMissing do
      render json: { error: "bad_request" }, status: :bad_request
    end
  end

  private

  # nil quando ausente; o valor quando é escalar; 400 quando é array ou hash.
  def optional_scalar_param(key)
    value = params[key]
    return value if value.nil? || !(value.is_a?(Array) || value.is_a?(ActionController::Parameters))

    raise ActionController::ParameterMissing, key
  end
end
