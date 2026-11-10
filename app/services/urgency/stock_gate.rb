# Módulo 32b: baixa de estoque pela medicação da UPA. Sem o interruptor
# utilizável (urgência e farmácia utilizáveis), a checagem não baixa estoque.
# Lido fora da transação da cidade.
module Urgency
  module StockGate
    KEY = "urgency_stock_deduction".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
