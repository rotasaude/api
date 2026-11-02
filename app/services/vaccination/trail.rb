# Trilha da leitura nominal da sala de vacina (ADR 0047, Desvio 20): o mesmo
# clinical_record.viewed do 19a, access "vaccination", sem evento novo. Uma por
# pessoa mostrada (caderneta, conferência, dose, transcrição, cancelamento,
# busca de pessoa), com person_ref. Só ids: nunca nome, CPF, CNS nem vacina.
module Vaccination
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
