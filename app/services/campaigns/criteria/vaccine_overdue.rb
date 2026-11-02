# Vacina em atraso: só caderneta CONFERIDA com série `overdue` (ADR 0047). Sem
# conferência o atraso é desconhecido (status `unchecked`) e ninguém é convocado
# por ele — quem não tem conferência é o critério vaccination_record_unchecked.
module Campaigns
  module Criteria
    class VaccineOverdue
      def self.relation(params)
        codes = Array(params["immunobiological_codes"]).map { |c| Vaccination::Immunobiologicals.normalize(c) }
        Criteria.vaccination_citizens(
          VaccinationStatus.where(status: "overdue", checked: true, immunobiological_code: codes), params
        )
      end
    end
  end
end
