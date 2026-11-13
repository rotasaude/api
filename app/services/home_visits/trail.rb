# Trilha da leitura nominal da visita (módulo 24b, ADR 0052; contrato §13): o
# mesmo clinical_record.viewed do 19a/24a, access "home_visits" (telas da
# equipe, §6 e §8) ou "field_sync" (download do app, §9). Só ids — nunca
# motivo, medida, observação, nome ou documento. Contexto, contagens e listas
# sem pessoa não gravam.
module HomeVisits
  module Trail
    module_function

    # Uma por consulta: as visitas mostradas (e os pacientes delas, se houver).
    def visits_viewed!(user:, home_visit_ids:, patient_ids:, access: Catalog::TRAIL_ACCESS)
      DomainEvents.publish("clinical_record.viewed", access: access, home_visit_ids: home_visit_ids, patient_ids: patient_ids.uniq,
                                                     user_id: user.id)
    end

    # "Quem visitar" (§8): uma por página, com a microárea e os pacientes mostrados.
    def people_listed!(user:, micro_area_id:, patient_ids:, access: Catalog::TRAIL_ACCESS)
      DomainEvents.publish("clinical_record.viewed", access: access, micro_area_id: micro_area_id, patient_ids: patient_ids.uniq,
                                                     user_id: user.id)
    end

    # Uma por pessoa mostrada fora de uma visita (busca), como o 23/24a.
    def person_viewed!(user:, patient_id:, access: Catalog::TRAIL_ACCESS)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: access, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
