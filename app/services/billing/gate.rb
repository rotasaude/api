# Interruptor do módulo 22 (ADR 0039; contrato §1). Lê só city_features na
# plataforma (Platform::Features.enabled?), sem abrir a cidade: seguro
# dentro da transação da cidade (o consumidor de lab_report.released roda
# nela). As rotas valem com a chave ligada; o `requires` (ibge_code) só
# informa o maintenance — sem IBGE o BPA-I sai com o campo em brancos.
module Billing
  module Gate
    KEY = "procedure_billing".freeze

    module_function

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end
  end
end
