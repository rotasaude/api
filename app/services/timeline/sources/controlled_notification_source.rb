# Registro da Notificação de Receita de papel (19d). Profissional: tipo,
# item e número do talão. Cidadão: "Receita de controle especial (talão)",
# sem número, sem PDF (o registro não tem impresso nem conferência).
module Timeline
  module Sources
    module ControlledNotificationSource
      KIND = "controlled_notification".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::ClinicalDocument.where(citizen_id: person.citizen_ids, kind: ClinicalDocumentSource::NOTIFICATION)
                                  .includes(attendance: :health_unit, author_user: :professional)
        Window.apply(scope, kind: KIND, column: "clinical_documents.issued_at", id_column: "clinical_documents.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |document| entry(document) }
      end

      def entry(document)
        content = document.content_data
        unit = document.attendance.health_unit
        item = content.dig("item", "printed_description")
        Entry.new(kind: KIND, source_id: document.id, occurred_at: document.issued_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: { name: Screenings::Json.staff_name(document.author_user), cbo_code: document.cbo_code },
                  title: "Notificação de receita #{content['notification_type']} (papel)",
                  summary: [ item, "talão #{content['paper_number']}" ].compact.join(" · "),
                  status: document.status, detail_ref: { type: "clinical_document", id: document.id },
                  citizen: { title: "Receita de controle especial (talão)", summary: nil, status: document.status,
                             professional_name: Labels.professional_name(document.author_user) },
                  document: nil)
      end
    end
  end
end
