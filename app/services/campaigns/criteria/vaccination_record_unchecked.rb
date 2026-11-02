# Caderneta ainda não conferida (sem nenhuma conferência do paciente): a
# campanha pede que leve a caderneta à unidade (ADR 0047).
module Campaigns
  module Criteria
    class VaccinationRecordUnchecked
      def self.relation(params)
        Criteria.vaccination_citizens(VaccinationStatus.where(checked: false), params)
      end
    end
  end
end
