# Interruptor do módulo 27a (ADR 0045): farmácia e almoxarifado. Sem
# pré-requisito (`requires: []`): rotas e jobs usam usable?.
module Pharmacy
  module Gate
    KEY = "pharmacy".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
