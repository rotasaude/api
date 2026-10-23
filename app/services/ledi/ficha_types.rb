# Tipos de ficha que o exportador conhece: tipoDadoSerializado (camada de
# transporte), a classe Thrift mestre e o campo do uuid da ficha. Ficha nova
# (módulos 18, 19, 22, 24) entra aqui.
module Ledi
  module FichaTypes
    class UnknownType < StandardError; end

    REGISTRY = {
      "procedimento" => { code: 7, klass: "Br::Gov::Saude::Esusab::Ras::Atendprocedimentos::FichaProcedimentoMasterThrift",
                          uuid_field: :uuidFicha },
      # ADR 0030 (Task 1): escuta inicial por nível superior. O código é o
      # tipo_dado_serializado.atendimento_individual de config/ledi/screening_mapping.yml
      # (spec de initial_listening confere os dois).
      "atendimento_individual" => { code: 4, klass: "Br::Gov::Saude::Esusab::Ras::Atendindividual::FichaAtendimentoIndividualMasterThrift",
                                    uuid_field: :uuidFicha },
      # Módulo 24a (ADR 0042): códigos conferidos na prova técnica
      # (vendor/ledi/8.7.0/docs, spec/services/ledi/registration_dictionaries_spec.rb).
      "cadastro_individual" => { code: 2, klass: "Br::Gov::Saude::Esusab::Ras::Cadastroindividual::CadastroIndividualThrift",
                                 uuid_field: :uuid },
      "cadastro_domiciliar" => { code: 3, klass: "Br::Gov::Saude::Esusab::Ras::Cadastrodomiciliar::CadastroDomiciliarThrift",
                                 uuid_field: :uuid }
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
