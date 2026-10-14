# Identificação do paciente no FHIR (Divergência D7; contrato A7): sistemas
# da RNDS. CPF compara com o do paciente; CNS com o de um par validado da
# pessoa (citizens.cns é cifrado não determinístico: lido por par, nunca
# buscado). Qualquer outro sistema não identifica ninguém.
module Exams
  module Fhir
    module Identifiers
      CPF_SYSTEM = "http://rnds.saude.gov.br/fhir/r4/NamingSystem/cpf".freeze
      CNS_SYSTEM = "http://rnds.saude.gov.br/fhir/r4/NamingSystem/cns".freeze

      module_function

      def matches?(patient, identifier)
        return false unless patient && identifier.is_a?(Hash)

        value = identifier["value"].to_s
        return false if value.empty?

        case identifier["system"]
        when CPF_SYSTEM then ActiveSupport::SecurityUtils.secure_compare(value, patient.cpf.to_s)
        when CNS_SYSTEM
          pairs = Citizen.not_erased.verification_level_verified
          pairs.where(patient_id: patient.id).or(pairs.where(cpf: patient.cpf))
               .any? { |c| c.cns.present? && ActiveSupport::SecurityUtils.secure_compare(c.cns.to_s, value) }
        else false
        end
      end

      def for_patient(patient) = { system: CPF_SYSTEM, value: patient.cpf }
    end
  end
end
