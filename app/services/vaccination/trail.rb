# Trilha da leitura nominal da sala de vacina (ADR 0047, Desvio 20): o mesmo
# clinical_record.viewed do 19a, access "vaccination", sem evento novo. Uma por
# pessoa mostrada (caderneta, conferência, dose, transcrição, cancelamento,
# busca de pessoa), com person_ref. Só ids: nunca nome, CPF, CNS nem vacina.
module Vaccination
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    # reason_code: o motivo da abertura justificada (leitura pela regra da
    # linha do tempo, como o 19a/20); nulo na leitura pela equipe da sala.
    def person_viewed!(user:, patient_id:, reason_code: nil)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: reason_code,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
