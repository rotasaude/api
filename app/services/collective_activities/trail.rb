# Trilha da leitura nominal da atividade coletiva (módulo 24b, ADR 0052;
# contrato §13): o mesmo clinical_record.viewed do 19a/24a, access
# "collective_activities". Só ids — nunca tema, público, prática, avaliação,
# nome ou documento. Nasce com a busca de pessoa (Task 7); a Task 15 acrescenta
# a leitura da atividade (Ruling A6). Opções, contagens e a lista (sem
# participantes) não gravam.
module CollectiveActivities
  module Trail
    module_function

    # Uma por resposta com atividade completa (registro, detalhe, "por
    # engano"): as atividades mostradas e os pacientes participantes.
    def activities_viewed!(user:, collective_activity_ids:, patient_ids:)
      DomainEvents.publish("clinical_record.viewed", access: Catalog::TRAIL_ACCESS, collective_activity_ids: collective_activity_ids,
                                                     patient_ids: patient_ids.uniq, user_id: user.id)
    end

    # Uma por pessoa mostrada fora de uma atividade (busca, candidatos do duplicado).
    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, person_ref: "patient:#{patient_id}")
    end
  end
end
