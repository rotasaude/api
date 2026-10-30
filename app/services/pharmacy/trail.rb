# Trilha da leitura nominal da farmácia (contrato §13 H12; Desvio 13): o mesmo
# clinical_record.viewed do 19a, access "pharmacy", sem evento novo, como a
# vigilância e o cadastro territorial. Um por pessoa mostrada, com person_ref.
# Só ids: nunca nome, CPF, CNS nem medicamento.
module Pharmacy
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
