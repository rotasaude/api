# Trilha da busca de pessoa e dos duplicados da central (§14 T2, na forma do
# 24a/V21): o mesmo clinical_record.viewed do 19a, access "transport", sem
# evento novo, uma por pessoa mostrada. O resto da central não deixa trilha
# (sem dado clínico; plano, Desvio 18). Só ids: nunca nome, CPF nem CNS.
module Transport
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
