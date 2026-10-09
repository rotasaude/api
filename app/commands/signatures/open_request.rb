# Abre o pedido de assinatura de um documento recém-finalizado (ADR 0032; spec
# §5): só com o interruptor utilizável (digital_signature e seus requisitos) e
# o autor com certificado ativo (adoção por profissional — sem certificado, o
# documento é manual). Um por documento (índice único; o consumidor pode
# repetir). O assinante do adendo é sempre a autora da consulta.
module Signatures
  module OpenRequest
    module_function

    def call(document, now: Time.current)
      return :unusable unless Gate.usable?(Current.city)
      return :manual unless SignerCertificate.active.exists?(user_id: document.author_user_id)

      inserted = SignatureRequest.insert_all(
        [ { document_type: DocumentTypes.db(document), document_id: document.id,
            consultation_id: DocumentTypes.consultation_id(document), author_user_id: document.author_user_id,
            status: "pending", attempts: 0, created_at: now, updated_at: now } ],
        unique_by: :idx_signature_requests_document, returning: [ :id ]
      )
      return :exists if inserted.rows.empty?

      SignJob.perform_later(city_slug: Current.city.slug, request_id: inserted.rows.first.first)
      :created
    end
  end
end
