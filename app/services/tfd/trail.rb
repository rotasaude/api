# Trilha da leitura nominal do processo de TFD (plano, Desvio 18): o mesmo
# clinical_record.viewed do 19a, access "tfd", só em POST /tfd/cases/:id/read
# (comissão ou autor). O pré-preenchimento não deixa (a consulta já deixa).
# Só ids: nunca nome, CID nem justificativa.
module Tfd
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
