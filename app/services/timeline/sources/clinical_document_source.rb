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
              .limit(limit).to_a.then do |page|
                signed = signed_ids(page)
                page.map { |document| entry(document, signed_ids: signed) }
              end
      end

      # Ids dos documentos digitais da página que já têm assinatura assinada —
      # uma consulta só, em vez de signed_signature por documento.
      def signed_ids(documents)
        ids = documents.select(&:digital?).map(&:id)
        return Set.new if ids.empty?

        ::SignatureRequest.joins(:signature)
                          .where(document_type: "ClinicalDocument", document_id: ids, status: "signed")
                          .distinct.pluck(:document_id).to_set
      end

      def entry(document, signed_ids:)
        unit = document.attendance.health_unit
        name = Labels.professional_name(document.author_user)
        title = title(document)
        Entry.new(kind: KIND, source_id: document.id, occurred_at: document.issued_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: { name: Screenings::Json.staff_name(document.author_user), cbo_code: document.cbo_code },
                  title: title, summary: "#{Labels::MODES[document.issue_mode]} · #{Labels::DOCUMENT_STATUS[document.status]}",
                  status: document.status, detail_ref: { type: "clinical_document", id: document.id },
                  citizen: { title: title, summary: nil, status: document.status, professional_name: name },
                  document: document_block(document, signed_ids))
      end

      def title(document)
        category = document.prescription? ? document.content_data["category"] : nil
        Labels::CATEGORIES[category] || Labels::DOCUMENT_KINDS.fetch(document.kind, document.kind)
      end

      def document_block(document, signed_ids)
        { id: document.id, short_code: document.short_code, verification_url: document.verification_url,
          downloadable: downloadable?(document, signed_ids) }
      end

      def downloadable?(document, signed_ids)
        return false if document.cancelled?

        document.digital? ? signed_ids.include?(document.id) : true
      end
    end
  end
end
