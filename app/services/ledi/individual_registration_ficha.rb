# Ficha de Cadastro Individual de cada IndividualRegistrationVersion (módulo
# 24a, ADR 0042). Comportamento em Ledi::RegistrationFicha; aqui, os valores da
# versão e os motivos próprios: paciente sem CPF e sem CNS →
# patient_without_identifier (Desvio 7; o LEDI exige CNS sem CPF); sem
# nascimento → citizen_without_birth_date.
module Ledi
  module IndividualRegistrationFicha
    extend Ledi::RegistrationFicha

    SOURCE_TYPE = Ledi::Fichas::IndividualRegistration::SOURCE_TYPE
    LEDI_TABLE = :individual

    class << self
      def version_class = IndividualRegistrationVersion
      def ficha_class = Ledi::Fichas::IndividualRegistration

      # As versões do mesmo cadastro (a originadora é a mais antiga delas).
      def sibling_ids(version) = IndividualRegistrationVersion.where(registration_id: version.registration_id).select(:id)

      # [values, motivos]: identidade e seções decifradas da versão.
      def values(version)
        identity = version.identity.to_h
        reasons = []
        reasons << "citizen_without_birth_date" unless TerritoryRegistry::Dictionary.iso_date(identity["birth_date"])
        reasons << "patient_without_identifier" if identity["cpf"].blank? && identity["cns"].blank?
        values = {
          "identity" => identity, "identification" => version.identification, "sociodemographic" => version.sociodemographic,
          "health_conditions" => version.health_conditions, "street_situation" => version.street_situation,
          "refused" => version.refused?, "micro_area_code" => version.micro_area&.code, "is_responsible" => version.is_responsible,
          "responsible" => responsible(version), "exit" => exit_values(version)
        }
        [ values, reasons ]
      end

      private

      # CPF/CNS do responsável da família, quando quem se cadastra não é ele.
      def responsible(version)
        return nil if version.is_responsible || version.family.nil?

        patient = version.family.responsible_patient
        { "cpf" => patient.cpf, "cns" => patient.cns }
      end

      def exit_values(version)
        return nil if version.exit_reason.blank?

        { "reason" => version.exit_reason, "on" => version.exited_on&.iso8601, "death_on" => version.death_on&.iso8601,
          "death_certificate" => version.death_certificate }
      end
    end
  end
end
