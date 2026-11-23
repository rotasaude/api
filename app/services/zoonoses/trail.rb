# Trilhas do centro de zoonoses (módulo 35b, ADR 0054; contrato §16, Q25,
# Q26). Só ids, nunca nome, CPF, CNS, microchip ou endereço.
#   - person_viewed!: a pessoa mostrada pela busca do tutor (POST
#     /zoonoses/person_lookup), pelo mesmo clinical_record.viewed das buscas de
#     pessoa dos outros módulos (access zoonoses, com person_ref); o domicílio
#     mostrado com ela, pela trilha do 24a (TerritoryRegistry::Trail), como o
#     endereço do caso do bloqueio do 35a;
#   - animal_viewed!: o detalhe do animal com tutor, pelo evento de domínio
#     `animal.viewed` (Q26, molde do transmission_block_case.address_viewed).
module Zoonoses
  module Trail
    ACCESS = "zoonoses".freeze

    module_function

    def person_viewed!(user:, patient_id:, household_id: nil)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
      TerritoryRegistry::Trail.household_viewed!(user: user, household_id: household_id) if household_id
    end

    def animal_viewed!(user:, animal_id:)
      DomainEvents.publish("animal.viewed", animal_id: animal_id, user_id: user.id)
    end
  end
end
