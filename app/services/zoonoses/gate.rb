# Interruptor do módulo 35b (ADR 0054; contrato §1, Q10): o centro de
# zoonoses. Utilizável = ligado e com o cadastro territorial utilizável pelo
# critério do TerritoryRegistry::Gate (IBGE e UF não fecham as rotas). Sem
# cascata para o vector_control: o 35b funciona com ou sem o 35a. O casa a
# casa e o app pedem também a visita domiciliar (field_usable?); o que o 35b
# acrescenta à ouvidoria pede a ouvidoria utilizável (ombudsman_usable?, Q10).
# Lido fora da transação da cidade e passado como argumento (`zoonoses:`), no
# padrão do `vector_control:`.
module Zoonoses
  module Gate
    KEY = "zoonoses".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY) && TerritoryRegistry::Gate.usable?(city)
    end

    def field_usable?(city) = usable?(city) && HomeVisits::Gate.usable?(city)

    def ombudsman_usable?(city) = usable?(city) && Ombudsman::Gate.usable?(city)
  end
end
