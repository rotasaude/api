# Trilha da leitura nominal da vigilância (contrato §15 K8; plano, Desvio 11;
# ruling R8): o mesmo clinical_record.viewed do 19a, access "surveillance", sem
# evento novo, como o TerritoryRegistry::Trail. Pessoa: um por pessoa mostrada
# (detalhe, PDF, criação manual), com person_ref. Lista: um por requisição,
# só os ids das notificações. Nunca nome, CPF, doença nem ficha.
module Surveillance
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:, citizen_id: nil)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: patient_id ? "patient:#{patient_id}" : "citizen:#{citizen_id}")
    end

    def listed!(user:, notification_ids:)
      DomainEvents.publish("clinical_record.viewed", access: ACCESS, notification_ids: notification_ids, user_id: user.id)
    end
  end
end
