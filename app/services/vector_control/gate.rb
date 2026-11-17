# Interruptor do módulo 35a (ADR 0054): vigilância ambiental de endemias.
# Utilizável = ligado e com a visita domiciliar utilizável (HomeVisits::Gate,
# que já exige o cadastro territorial; Q1). Lido fora da transação da cidade e
# passado como argumento (`vector_control:`), no padrão do `home_visits:`.
module VectorControl
  module Gate
    KEY = "vector_control".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY) && HomeVisits::Gate.usable?(city)
    end
  end
end
