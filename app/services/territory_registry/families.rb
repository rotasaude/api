# Família com responsável que saiu (contrato §14 L29): família ATIVA cujo
# responsável teve óbito (em qualquer cadastro dele) ou teve o cadastro deste
# domicílio encerrado (mudança) sem outro cadastro ativo aqui. O <family> leva
# responsible_exited; o retrato da versão do domicílio também, e a ficha
# domiciliar deixa essa família de fora (o FamiliaRow não exige responsável
# vivo: nunca mandar o falecido como responsável de família ativa). A saída
# do responsável sozinha não gera versão do domicílio: vale a partir da
# próxima gravação. Família em mudança nunca conta.
module TerritoryRegistry
  module Families
    module_function

    # Set dos ids, com uma consulta.
    def responsible_exited_ids(families)
      active = families.reject(&:moved_out)
      return Set.new if active.empty?

      rows = IndividualRegistration.where(patient_id: active.map(&:responsible_patient_id).uniq)
                                   .pluck(:patient_id, :household_id, :exit_reason).group_by(&:first)
      active.filter_map do |family|
        mine = rows.fetch(family.responsible_patient_id, [])
        here = mine.select { |_, household_id, _| household_id == family.household_id }
        dead = mine.any? { |_, _, reason| reason == "death" }
        left = here.any? { |_, _, reason| reason.present? } && here.none? { |_, _, reason| reason.nil? }
        family.id if dead || left
      end.to_set
    end
  end
end
