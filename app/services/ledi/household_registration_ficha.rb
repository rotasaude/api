# Ficha de Cadastro Domiciliar e Territorial de cada HouseholdVersion (módulo
# 24a, ADR 0042). Comportamento em Ledi::RegistrationFicha; aqui, os valores da
# versão e o motivo próprio: família cujo responsável não tem CPF nem CNS →
# responsible_without_identifier (Desvio 7; FamiliaRow exige um dos dois).
# families_snapshot (gravado pelo SaveHousehold, Task 9): [{ "family_id",
# "responsible_patient_id", "income_band", "members_count", "living_since",
# "moved_out", "responsible_exited" }]; o CPF/CNS e o nascimento do responsável
# vêm do paciente. Família ativa com responsible_exited (§14 L29: o
# responsável saiu por óbito ou mudança) fica fora da ficha — o FamiliaRow
# não exige responsável vivo, e a ficha nunca manda o falecido como
# responsável de família ativa; a família em mudança segue (stMudanca).
module Ledi
  module HouseholdRegistrationFicha
    extend Ledi::RegistrationFicha

    SOURCE_TYPE = Ledi::Fichas::HouseholdRegistration::SOURCE_TYPE
    LEDI_TABLE = :household
    PROFILE_FIELDS = %i[ibge_code uf].freeze # contrato §14 L20

    class << self
      def version_class = HouseholdVersion
      def ficha_class = Ledi::Fichas::HouseholdRegistration

      # As versões do mesmo domicílio (a originadora é a mais antiga delas).
      def sibling_ids(version) = HouseholdVersion.where(household_id: version.household_id).select(:id)

      # [values, motivos]: endereço, moradia e famílias decifrados da versão.
      def values(version)
        families = families(version)
        reasons = families.any? { |row| row["cpf"].blank? && row["cns"].blank? } ? [ "responsible_without_identifier" ] : []
        address = version.address.to_h
        address = address.merge("district" => version.neighborhood.name) if version.neighborhood
        values = {
          "property_type" => version.property_type, "refused" => version.refused?, "status" => version.status,
          "micro_area_code" => version.micro_area.code, "uf" => CityProfile.current&.uf, "contact_phone" => version.contact_phone,
          "address" => address, "living_conditions" => version.living_conditions, "families" => families
        }
        [ values, reasons ]
      end

      private

      def families(version)
        rows = Array(version.families_snapshot).reject { |row| row["responsible_exited"] == true && row["moved_out"] != true }
        patients = Patient.where(id: rows.map { |row| row["responsible_patient_id"] }).index_by(&:id)
        rows.map do |row|
          patient = patients[row["responsible_patient_id"]]
          { "cpf" => patient&.cpf, "cns" => patient&.cns, "birth_date" => TerritoryRegistry::Dictionary.iso_date(patient&.birth_date),
            "members_count" => row["members_count"], "income_band" => row["income_band"], "living_since" => row["living_since"],
            "moved_out" => row["moved_out"] == true }
        end
      end
    end
  end
end
