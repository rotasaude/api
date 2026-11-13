# Trilha da leitura nominal da atividade coletiva (módulo 24b, ADR 0052;
# contrato §13): o mesmo clinical_record.viewed do 19a/24a, access
# "collective_activities". Só ids — nunca tema, público, prática, avaliação,
# nome ou documento. Nasce com a busca de pessoa (Task 7); a Task 15 acrescenta
# a leitura da atividade.
module CollectiveActivities
  module Trail
    module_function

    # Uma por pessoa mostrada fora de uma atividade (busca, candidatos do duplicado).
    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, person_ref: "patient:#{patient_id}")
    end
  end
end
