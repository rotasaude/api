# Trilha da leitura nominal do cadastro territorial (contrato §14 L11; plano,
# Desvio 11 com o ruling C11): o mesmo clinical_record.viewed do 19a, access
# territory_registry, sem evento novo. Domicílio: um por consulta (lista ou
# detalhe), com os ids mostrados; pessoa: um por pessoa mostrada, como o 23
# (person_ref). Só ids, nunca endereço, moradia ou nome.
module TerritoryRegistry
  module Trail
    ACCESS = "territory_registry".freeze

    module_function

    def households_listed!(user:, micro_area_id:, household_ids:)
      DomainEvents.publish("clinical_record.viewed", access: ACCESS, micro_area_id: micro_area_id, household_ids: household_ids,
                                                     user_id: user.id)
    end

    def household_viewed!(user:, household_id:)
      DomainEvents.publish("clinical_record.viewed", access: ACCESS, household_id: household_id, user_id: user.id)
    end

    def person_viewed!(user:, patient_id:, citizen_id: nil)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: patient_id ? "patient:#{patient_id}" : "citizen:#{citizen_id}")
    end
  end
end
