# Identificação do paciente no FHIR (Divergência D7; contrato A7): sistemas
# da RNDS. CPF compara com o do paciente; CNS com o de um par validado da
# pessoa (citizens.cns é cifrado não determinístico: lido por par, nunca
# buscado) ou com o do próprio paciente (módulo 24a). Qualquer outro sistema
# não identifica ninguém. O paciente sem CPF sai pelo CNS; sem os dois, nil.
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
        when CPF_SYSTEM then patient.cpf.present? && ActiveSupport::SecurityUtils.secure_compare(value, patient.cpf.to_s)
        when CNS_SYSTEM
          [ patient.cns, *Patients::Pairs.of(patient).map(&:cns) ]
            .any? { |cns| cns.present? && ActiveSupport::SecurityUtils.secure_compare(cns.to_s, value) }
        else false
        end
      end

      def for_patient(patient)
        return { system: CPF_SYSTEM, value: patient.cpf } if patient.cpf.present?

        patient.cns.present? ? { system: CNS_SYSTEM, value: patient.cns } : nil
      end
    end
  end
end
