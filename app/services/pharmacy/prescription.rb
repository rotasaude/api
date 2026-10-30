# A receita vista pela farmácia (ADR 0045): o envelope único da receita do 19c
# (`digital`: clinical_documents + prescription_items, no papel também) e da
# externa (`external`). `Pharmacy::Prescription.find` e as buscas leem o
# catálogo da plataforma, por isso rodam FORA da transação da cidade.
#
# Nada pessoal em inspect, to_s, pretty_print nem as_json: só `kind` e `id`
# (o envelope e cada item carregam posologia, medicamento e o prescritor).
#
# `controlled` do item: o catálogo da plataforma o marca `controlled` OU o
# conteúdo do 19c é `category == "special_control"` (vale para todos os itens
# da receita, mesmo que o catálogo atual tenha deixado de marcá-los).
#
# `retention_required` do item (H6/H12): o catálogo da plataforma o marca
# `antimicrobial` OU `controlled`, OU o conteúdo do 19c é `category ==
# "special_control"` (vale para todos os itens da receita). Receita externa:
# `antimicrobial` do catálogo OU o retrato da lista de controle gravado no item
# (`controlled_list`); quem digita a externa não marca nada.
module Pharmacy
  class Prescription < Data.define(:kind, :id, :record, :patient_id, :issued_on, :cancelled, :sncr_number, :items, :prescriber)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def inspect = "#<Pharmacy::Prescription kind=#{kind} id=#{id}>"
    def to_s = inspect
    def pretty_print(pp) = pp.text(inspect)
    def as_json(*) = { "kind" => kind, "id" => id }

    # Item da receita: `id` é o do prescription_item (digital) ou do
    # external_prescription_item; `catalog_item_id` nulo = texto livre.
    class Item < Data.define(:id, :catalog_item_id, :free_text, :printed_description, :quantity, :quantity_unit, :dosage_instructions,
                             :continuous, :controlled, :controlled_list, :antimicrobial, :retention_required, :valid_until)
      def inspect = "#<Pharmacy::Prescription::Item id=#{id}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "id" => id }
    end

    # Receita do 19c (`kind == "prescription"`; digital ou em papel).
    # `catalog` = { catalog_item_id => MedicationCatalogItem }.
    def self.digital(document, catalog:, settings:)
      raise ArgumentError, "not a prescription" unless document.prescription?

      content = document.content_data
      explicit = content["valid_until"].presence && Date.iso8601(content["valid_until"])
      issued_on = document.issued_at.in_time_zone.to_date
      special_control = content["category"] == "special_control"
      items = document.prescription_items.map do |row|
        entry = row.medication_catalog_item_id && catalog[row.medication_catalog_item_id]
        # Receita de controle especial do 19c: todo item vale como controlado,
        # mesmo que o catálogo de hoje já não o marque (a receita foi emitida
        # assim; só o farmacêutico dispensa e o número SNCR fica na retenção).
        controlled = entry&.controlled == true || special_control
        antimicrobial = entry&.antimicrobial == true
        valid_until = Validity.item_until(issued_on: issued_on, explicit: explicit, continuous: row.continuous, controlled: controlled,
                                          external: false, settings: settings)
        Item.new(id: row.id, catalog_item_id: row.medication_catalog_item_id, free_text: row.free_text,
                 printed_description: row.printed_description, quantity: row.quantity, quantity_unit: row.quantity_unit,
                 dosage_instructions: row.dosage_instructions, continuous: row.continuous, controlled: controlled,
                 controlled_list: entry&.controlled_list, antimicrobial: antimicrobial,
                 retention_required: antimicrobial || controlled || special_control, valid_until: valid_until)
      end
      author = document.author_user
      # O número SNCR só vale na receita digital: a que voltou ao papel guarda o número anulado.
      sncr = document.digital? ? content.dig("sncr", "number") : nil
      new(kind: "digital", id: document.id, record: document, patient_id: document.patient_id, issued_on: issued_on,
          cancelled: document.cancelled?, sncr_number: sncr, items: items,
          prescriber: { name: author.professional&.professional_name, council: ClinicalDocuments::Json.council(author.professional) })
    end

    # Receita externa digitada na farmácia. O prazo de 30 dias do item
    # controlado vale pelo retrato da lista gravado na receita.
    def self.external(record, catalog:, settings:)
      items = record.items.map do |row|
        entry = catalog[row.catalog_item_id]
        controlled = row.controlled_list.present?
        antimicrobial = entry&.antimicrobial == true
        valid_until = Validity.item_until(issued_on: record.issued_on, explicit: nil, continuous: row.continuous, controlled: controlled,
                                          external: true, settings: settings)
        Item.new(id: row.id, catalog_item_id: row.catalog_item_id, free_text: nil, printed_description: entry&.label.to_s,
                 quantity: row.quantity, quantity_unit: row.quantity_unit, dosage_instructions: row.dosage_instructions,
                 continuous: row.continuous, controlled: controlled, controlled_list: row.controlled_list,
                 antimicrobial: antimicrobial, retention_required: antimicrobial || controlled, valid_until: valid_until)
      end
      new(kind: "external", id: record.id, record: record, patient_id: record.patient_id, issued_on: record.issued_on, cancelled: false,
          sncr_number: nil, items: items,
          prescriber: { name: record.prescriber_name, council: "#{record.council}-#{record.council_state} #{record.council_number}" })
    end

    # A receita pelo id (uuid; senão nil), com o catálogo atual da plataforma.
    def self.find(kind:, id:, settings:)
      return nil unless id.is_a?(String) && id.match?(UUID)

      case kind
      when "digital"
        document = ClinicalDocument.includes(:prescription_items, author_user: :professional).find_by(id: id, kind: "prescription")
        document && digital(document, catalog: catalog_for(document.prescription_items.filter_map(&:medication_catalog_item_id)), settings: settings)
      when "external"
        record = ExternalPrescription.includes(:items).find_by(id: id)
        record && external(record, catalog: catalog_for(record.items.map(&:catalog_item_id)), settings: settings)
      end
    end

    # Receitas do paciente desde `since` (data da cidade; as do 19c, em papel
    # inclusive, e as externas), mais novas primeiro, até `limit`. Notificação
    # de controlado (`controlled_notification_record`) NÃO é receita.
    def self.recent(patient_id:, since:, limit:, settings:)
      documents = ClinicalDocument.includes(:prescription_items, author_user: :professional)
                                  .where(kind: "prescription", patient_id: patient_id, issued_at: since.in_time_zone..)
                                  .order(issued_at: :desc, id: :desc).limit(limit).to_a
      externals = ExternalPrescription.includes(:items).where(patient_id: patient_id, issued_on: since..)
                                      .order(issued_on: :desc, created_at: :desc, id: :desc).limit(limit).to_a
      catalog = catalog_for(documents.flat_map { |doc| doc.prescription_items.filter_map(&:medication_catalog_item_id) } +
                            externals.flat_map { |record| record.items.map(&:catalog_item_id) })
      all = documents.map { |doc| digital(doc, catalog: catalog, settings: settings) } +
            externals.map { |record| external(record, catalog: catalog, settings: settings) }
      all.sort_by { |prescription| [ prescription.issued_on, prescription.record.created_at, prescription.id ] }.reverse.first(limit)
    end

    def self.catalog_for(ids) = MedicationCatalogItem.where(id: ids.uniq).index_by(&:id)
  end
end
