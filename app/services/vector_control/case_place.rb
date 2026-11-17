# Lugar do caso de arbovirose (módulo 35a, ADR 0054; contrato §8, decisão
# 27): o cadastro individual ativo do paciente → o domicílio → o quarteirão do
# perfil do imóvel (household_vector_profiles.city_block_id). Faltando
# qualquer elo, o caso não tem lugar. Só ids: nunca endereço nem coordenada.
module VectorControl
  module CasePlace
    module_function

    # { patient_id => city_block_id } só dos que têm lugar, numa consulta.
    def blocks(patient_ids)
      ids = patient_ids.compact.uniq
      return {} if ids.empty?

      IndividualRegistration.where(patient_id: ids, exit_reason: nil)
                            .joins("JOIN household_vector_profiles ON household_vector_profiles.household_id = individual_registrations.household_id")
                            .where("household_vector_profiles.city_block_id IS NOT NULL")
                            .pluck(:patient_id, "household_vector_profiles.city_block_id").to_h
    end

    def block(patient_id) = blocks([ patient_id ])[patient_id]

    # O domicílio do cadastro individual ativo (ou nil).
    def household_id(patient_id) = IndividualRegistration.where(patient_id: patient_id, exit_reason: nil).pick(:household_id)
  end
end
