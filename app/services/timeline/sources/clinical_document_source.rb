# Documentos clínicos (19c/19d), menos o registro da Notificação (kind
# próprio). Profissional: tipo/categoria, modo e situação. Cidadão: tipo,
# data, situação, código e conferência; baixável quando não cancelado e
# (papel, ou digital já assinado). Conteúdo do documento nunca entra.
module Timeline
  module Sources
    module ClinicalDocumentSource
      KIND = "clinical_document".freeze
      NOTIFICATION = "controlled_notification_record".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::ClinicalDocument.where(citizen_id: person.citizen_ids).where.not(kind: NOTIFICATION)
                                  .includes(attendance: :health_unit, author_user: :professional)
        Window.apply(scope, kind: KIND, column: "clinical_documents.issued_at", id_column: "clinical_documents.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |document| entry(document) }
      end

      def entry(document)
        unit = document.attendance.health_unit
        name = Labels.professional_name(document.author_user)
        title = title(document)
        Entry.new(kind: KIND, source_id: document.id, occurred_at: document.issued_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: { name: Screenings::Json.staff_name(document.author_user), cbo_code: document.cbo_code },
                  title: title, summary: "#{Labels::MODES[document.issue_mode]} · #{Labels::DOCUMENT_STATUS[document.status]}",
                  status: document.status, detail_ref: { type: "clinical_document", id: document.id },
                  citizen: { title: title, summary: nil, status: document.status, professional_name: name },
                  document: document_block(document))
      end

      def title(document)
        category = document.prescription? ? document.content_data["category"] : nil
        Labels::CATEGORIES[category] || Labels::DOCUMENT_KINDS.fetch(document.kind, document.kind)
      end

      def document_block(document)
        { id: document.id, short_code: document.short_code, verification_url: document.verification_url,
          downloadable: downloadable?(document) }
      end

      def downloadable?(document)
        return false if document.cancelled?

        document.digital? ? document.signed_signature.present? : true
      end
    end
  end
end
