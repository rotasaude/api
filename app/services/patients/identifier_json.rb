# L8 do contrato do 24a: as formas que mostram o paciente (ou o par, quando
# ainda não há paciente) dizem se há CPF e o CNS mascarado (só os 4 últimos
# dígitos) — a tela mostra "sem CPF" e o CNS. Nunca o CPF nem o CNS inteiros.
module Patients
  module IdentifierJson
    module_function

    def call(person) = { has_cpf: person&.cpf.present? || false, cns_masked: person&.cns_masked }
  end
end
