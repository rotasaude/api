# Tipos de ficha que o exportador conhece: tipoDadoSerializado (camada de
# transporte), a classe Thrift mestre e o campo do uuid da ficha. Ficha nova
# (módulos 18, 19, 22, 24) entra aqui.
module Ledi
  module FichaTypes
    class UnknownType < StandardError; end

    REGISTRY = {
      "procedimento" => { code: 7, klass: "Br::Gov::Saude::Esusab::Ras::Atendprocedimentos::FichaProcedimentoMasterThrift",
                          uuid_field: :uuidFicha }
    }.freeze

    module_function

    def entry(type) = REGISTRY.fetch(type.to_s) { raise UnknownType, type.to_s }
    def code(type) = entry(type)[:code]
    def uuid_field(type) = entry(type)[:uuid_field]

    def klass(type)
      Ledi::Version.load!
      entry(type)[:klass].constantize
    end

    def type_for_code(code)
      REGISTRY.find { |_type, e| e[:code] == code }&.first or raise UnknownType, code.to_s
    end
  end
end
