# Documento da própria pessoa para o cidadão (ADR 0035; contrato §4): nunca
# o registro da Notificação; o PDF assinado (PAdES gravado) do digital já
# assinado, ou o de papel gerado agora. Digital pendente e cancelado: nil.
module Timeline
  module CitizenDocuments
    module_function

    def find(person:, id:)
      return nil unless id.is_a?(String) && ClinicalDocuments::Uuid.valid?(id)

      ClinicalDocument.where(citizen_id: person.citizen_ids)
                      .where.not(kind: Sources::ClinicalDocumentSource::NOTIFICATION).find_by(id: id)
    end

    def pdf(document)
      return nil if document.cancelled?

      document.digital? ? document.signed_signature&.signed_pdf_bytes : ClinicalDocuments::Pdf.call(document)
    end
  end
end
