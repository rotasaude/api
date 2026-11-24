# Trilhas do centro de zoonoses (módulo 35b, ADR 0054; contrato §16, Q25,
# Q26). Só ids, nunca nome, CPF, CNS, microchip ou endereço.
#   - person_viewed!: a pessoa mostrada pela busca do tutor (POST
#     /zoonoses/person_lookup), pelo mesmo clinical_record.viewed das buscas de
#     pessoa dos outros módulos (access zoonoses, com person_ref); o domicílio
#     mostrado com ela, pela trilha do 24a (TerritoryRegistry::Trail), como o
#     endereço do caso do bloqueio do 35a;
#   - animal_viewed!: o detalhe do animal com tutor, pelo evento de domínio
#     `animal.viewed` (Q26, molde do transmission_block_case.address_viewed);
#   - demand_viewed!: o detalhe da demanda (extrato e place_address), pelo
#     evento de domínio `zoonoses_demand.viewed` (Q13, Q26);
#   - observation_contact_viewed!: o contato da observação do animal agressor
#     (nome e telefone do tutor, endereço do animal, da ficha do 25), pelo
#     evento de domínio `bite_observation.contact_viewed` (§5, Q26).
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

    def demand_viewed!(user:, demand_id:)
      DomainEvents.publish("zoonoses_demand.viewed", zoonoses_demand_id: demand_id, user_id: user.id)
    end

    def observation_contact_viewed!(user:, observation_id:)
      DomainEvents.publish("bite_observation.contact_viewed", bite_observation_id: observation_id, user_id: user.id)
    end
  end
end
