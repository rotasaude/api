# Registro da Notificação de Receita de papel (ADR 0034; spec §5; contrato §3):
# o número do talão da VISA, a UF da numeração e UMA substância das listas
# A (A1–A3) ou B (B1, B2) do tipo certo, com quantidade, posologia e duração
# (Portaria 344: A ≤ 30 dias; B ≤ 60; B2 ≤ 60 — Valores fixados 3). Sem PDF,
# sem assinatura, sem conferência pública. Só médico e dentista.
module ClinicalDocuments
  module Content
    module NotificationRecord
      TYPES = { "A" => %w[A1 A2 A3], "B" => %w[B1], "B2" => %w[B2] }.freeze
      MAX_DAYS = { "A" => 30, "B" => 60, "B2" => 60 }.freeze
      PAPER_NUMBER = %r{\A[0-9A-Za-z./-]{1,30}\z}
      PRESCRIBERS = %i[physician dentist].freeze

      module_function

      def call(input, role:, catalog:)
        return Result.fail(:cbo_not_allowed) unless PRESCRIBERS.include?(role)

        input = Input.object(input)
        type = input["notification_type"]
        return Input.invalid("notification_type") unless TYPES.key?(type)

        paper = input["paper_number"].is_a?(String) ? input["paper_number"].strip : ""
        return Input.invalid("paper_number") unless paper.match?(PAPER_NUMBER)

        uf = input["numbering_uf"].is_a?(String) ? input["numbering_uf"].upcase : ""
        return Input.invalid("numbering_uf") unless Professional::UFS.include?(uf)

        item = Input.object(input["item"])
        reference = item["catalog_item"].is_a?(Hash) ? item["catalog_item"]["id"].to_s : nil
        entry = reference && catalog[reference]
        return Input.invalid("item.catalog_item") unless entry && entry.status == "active" && !entry.hidden
        return Result.fail(:item_not_in_notification_list) unless TYPES.values.flatten.include?(entry.controlled_list)
        return Result.fail(:notification_type_mismatch) unless TYPES.fetch(type).include?(entry.controlled_list)

        fields = item_fields(item)
        return fields if fields.is_a?(Result)
        return Result.fail(:duration_exceeded) if fields[:duration_days] > MAX_DAYS.fetch(type)

        content = { "notification_type" => type, "paper_number" => paper, "numbering_uf" => uf,
                    "item" => { "catalog_item" => Json.catalog_ref(entry).deep_stringify_keys, "printed_description" => entry.label,
                                "quantity" => Json.number(fields[:quantity]), "quantity_unit" => fields[:quantity_unit],
                                "route" => fields[:route], "dosage_instructions" => fields[:dosage_instructions],
                                "duration_days" => fields[:duration_days] } }
        Result.ok(content: content, items: [], category: nil, catalog_item: entry)
      end

      def item_fields(item)
        raw = item["quantity"]
        quantity = raw.is_a?(Numeric) || raw.to_s.match?(/\A\d+(\.\d+)?\z/) ? BigDecimal(raw.to_s) : nil
        return Input.invalid("item.quantity") unless quantity && quantity.positive? && quantity <= 9999 && quantity.round(2) == quantity

        unit = Input.text(item["quantity_unit"], 1..30)
        return Input.invalid("item.quantity_unit") unless unit.is_a?(String)
        return Input.invalid("item.route") unless PrescriptionItem::ROUTES.include?(item["route"])

        dosage = Input.text(item["dosage_instructions"], 3..500)
        return Input.invalid("item.dosage_instructions") unless dosage.is_a?(String)

        duration = item["duration_days"]
        return Input.invalid("item.duration_days") unless duration.is_a?(Integer) && duration.between?(1, 365)

        { quantity: quantity, quantity_unit: unit, route: item["route"], dosage_instructions: dosage, duration_days: duration }
      end
      private_class_method :item_fields
    end
  end
end
