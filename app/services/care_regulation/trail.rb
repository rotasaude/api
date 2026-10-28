# Trilha da leitura nominal da regulação (plano, Desvio 13; contrato §13 G6): o
# mesmo clinical_record.viewed do 19a, access "regulation", sem evento novo,
# como o Surveillance::Trail. Pessoa: um por pessoa mostrada (detalhe, guia),
# com person_ref. Lista: um por requisição, só os ids dos pedidos. Nunca nome,
# CPF, CID, justificativa nem alvo. Rascunhos na consulta não geram trilha (a
# consulta já deixa).
module CareRegulation
  module Trail
    ACCESS = Catalog::TRAIL_ACCESS

    module_function

    def person_viewed!(user:, patient_id:)
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: ACCESS, reason_code: nil,
                                                     person_ref: "patient:#{patient_id}")
    end

    def listed!(user:, regulation_request_ids:)
      DomainEvents.publish("clinical_record.viewed", access: ACCESS, regulation_request_ids: regulation_request_ids, user_id: user.id)
    end
  end
end
