# app/services/clinical_documents/json.rb
# Formas do contrato do 19c (§2, §5, §6): item do catálogo, protocolo,
# documento e medicamento em uso.
module ClinicalDocuments
  module Json
    module_function

    # <item> da busca (contrato §5) e da REMUME (§6).
    def catalog_item(item, in_network: nil)
      json = catalog_ref(item).merge(antimicrobial: item.antimicrobial, controlled: item.controlled,
                                     **catalog_marks(item))
      in_network.nil? ? json : json.merge(in_network: in_network)
    end

    # As marcas de controle (§12) saem em todo catalog_item HTTP, mas FORA do
    # `catalog_ref`, que vai ao JSON canônico assinado.
    def catalog_marks(item) = { controlled_list: item.controlled_list, anticonvulsant: item.anticonvulsant }

    # `catalog_item` dentro do <item> da receita e do <medication> (§2).
    def catalog_ref(item)
      { id: item.id, catmat_code: item.catmat_code, label: item.label, active_ingredient: item.active_ingredient,
        strength: item.strength, dosage_form: item.dosage_form }
    end

    # Número do JSON: inteiro quando não tem casas (30, não 30.0).
    def number(decimal)
      return nil if decimal.nil?

      value = BigDecimal(decimal.to_s)
      value.frac.zero? ? value.to_i : value.to_f
    end

    # Protocolo de enfermagem (contrato §6) com a versão vigente na data.
    def protocol(protocol, catalog:, on: Time.zone.today)
      version = protocol.current_version(on: on)
      { id: protocol.id, title: protocol.title, number: protocol.number, year: protocol.year,
        current_version: version && protocol_version(version, catalog: catalog) }
    end

    # Uma versão do protocolo; com `situation` no histórico (api#61).
    def protocol_version(version, catalog:, situation: nil)
      row = { id: version.id, version: version.version, valid_from: version.valid_from.iso8601,
              valid_until: version.valid_until&.iso8601,
              items: version.items.sort_by { |item| [ item.created_at, item.id ] }.filter_map do |item|
                entry = catalog[item.catalog_item_id]
                entry && { catalog_item: catalog_item(entry),
                           max_dose: item.max_quantity && { quantity: number(item.max_quantity), unit: item.max_quantity_unit } }
              end }
      situation ? row.merge(situation: situation) : row
    end

    # api#61: "vigente" é a que vale hoje; início no futuro = "agendada"; o resto, "encerrada".
    def version_situation(version, current, today)
      return "vigente" if current && version.id == current.id

      version.valid_from > today ? "agendada" : "encerrada"
    end

    # Texto do conselho ("CRM-PR 12345"), o mesmo no JSON, no PDF e na página
    # pública; nil sem perfil profissional (a recepção) e sem conselho (ACS e
    # agente de endemias, módulo 24a).
    def council(professional)
      return unless professional&.council

      "#{professional.council}-#{professional.council_state} #{professional.registration_number}"
    end

    # Linha das listas de declarações (api#59): só metadados — nada do conteúdo
    # nem o motivo do cancelamento; o nome é o que a fila já mostra.
    def declaration_row(document)
      person = document.patient || document.attendance.citizen
      { id: document.id, status: document.status, issued_at: document.issued_at.iso8601,
        cancelled_at: document.cancelled_at&.iso8601, short_code: Codes.display(document.short_code),
        attendance_id: document.attendance_id,
        author: { id: document.author_user_id, name: Screenings::Json.staff_name(document.author_user) },
        patient: person && { display_name: person.display_name } }
    end

    # <document> (contrato §2; 19d §12: `paper_reason` gravado e devolvido em
    # toda leitura, null no digital e na volta ao papel). `signature` = o bloco do 19b quando há pedido
    # (documento digital, ou que voltou ao papel); nil no papel puro. O `sncr`
    # do content só sai na receita digital (cancelada inclusive): a que voltou
    # ao papel guarda o número anulado no content, mas a leitura devolve null.
    def document(document, signature: :load)
      author = document.author_user
      signature = document.signature_request ? Signatures::Mode.for(document) : nil if signature == :load
      { id: document.id, kind: document.kind, status: document.status, issue_mode: document.issue_mode,
        paper_reason: document.paper_reason, issued_at: document.issued_at.iso8601, cancelled_at: document.cancelled_at&.iso8601,
        cancel_reason: document.cancel_reason,
        author: { id: author.id, name: Screenings::Json.staff_name(author),
                  council: council(author.professional),
                  cbo_code: document.cbo_code },
        patient: document.patient && { id: document.patient.id, display_name: document.patient.display_name },
        consultation_id: document.consultation_id, attendance_id: document.attendance_id,
        short_code: (Codes.display(document.short_code) unless document.notification_record?),
        verification_url: (document.verification_url unless document.notification_record?),
        replaces_document_id: document.replaces_document_id, content: content(document), signature: signature }
    end

    def content(document)
      data = document.content_data
      data["sncr"] = nil if document.prescription? && !document.digital? && data.key?("sncr")
      data
    end

    # <medication> (contrato §2); `catalog` = { id => MedicationCatalogItem };
    # `last_dispensed` = { catalog_item_id => Date } (27a, H7): `last_dispensed_on`
    # é a data da última retirada na farmácia (líquida de devolução total); texto
    # livre e item nunca dispensado → null.
    def medication(medication, catalog:, last_dispensed: {})
      item = medication.catalog_item_id && catalog[medication.catalog_item_id]
      { id: medication.id, catalog_item: item && catalog_ref(item).merge(catalog_marks(item)),
        free_text: medication.free_text, label: medication.label,
        dosage_summary: medication.dosage_summary, continuous: medication.continuous, status: medication.status,
        origin: medication.origin, started_on: medication.started_on&.iso8601, updated_at: medication.updated_at.iso8601,
        last_dispensed_on: medication.catalog_item_id && last_dispensed[medication.catalog_item_id]&.iso8601 }
    end
  end
end
