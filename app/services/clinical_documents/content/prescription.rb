# app/services/clinical_documents/content/prescription.rb
# Receita comum (ADR 0033; spec §5; Lei 5.991 art. 35; Lei 9.787 — DCB):
# itens do catálogo (código CATMAT e release da emissão) ou texto livre
# (marcado e varrido nas listas Anvisa). Controlado pela categoria (ADR 0034;
# Content::Controlled) quando `controlled_prescriptions` está utilizável;
# desligado, nenhum controlado. Antimicrobiano e controle especial: 2 vias e
# validade fixa (10 e 30 dias; RDC 471/2021, Portaria 344/1998). Ordem das
# checagens: forma dos itens → categoria → regras da categoria → enfermagem →
# validade.
# Enfermeiro (COFEN 801/2026): só itens da versão VIGENTE do protocolo
# escolhido, dentro da dose máxima (quantidade por item, mesma unidade), sem
# texto livre, com o CNPJ da cidade.
module ClinicalDocuments
  module Content
    module Prescription
      MAX_ITEMS = 20
      MAX_VALIDITY_DAYS = 365

      module_function

      def call(input, role:, patient:, catalog:, matcher:, today: Time.zone.today, city_cnpj: nil, controlled: false,
               prescriber_contact: nil)
        input = Input.object(input)
        raw = input["items"]
        return Input.invalid("items") unless raw.is_a?(Array) && raw.size.between?(1, MAX_ITEMS)

        problems = PatientProblem.where(patient_id: patient.id).pluck(:id).to_set
        items = []
        raw.each_with_index do |entry, index|
          parsed = item(entry, index, catalog, matcher, problems)
          return parsed if parsed.is_a?(Result)

          items << parsed
        end
        classified = controlled ? Controlled.classify(items) : Controlled.legacy(items)
        return classified if classified.failure?

        category = classified.payload[:category]
        rules = Controlled.check(category, items, role: role, identification: (input["patient_identification"] if controlled),
                                                  prescriber_contact: (prescriber_contact if controlled), patient: patient)
        return rules if rules.failure?

        version = nil
        if role == :nurse
          version = nursing(input, items, today, city_cnpj)
          return version if version.is_a?(Result)
        end
        antimicrobial = items.any? { |it| it[:antimicrobial] }
        valid_until = Controlled.validity(category, today) || validity(input, today)
        return valid_until if valid_until.is_a?(Result)

        rows = rows(items)
        content = { "items" => rows.zip(items).map { |row, it| content_item(row, it) },
                    "nursing_protocol" => version && protocol_json(version),
                    "city_cnpj" => (city_cnpj if version), "antimicrobial" => antimicrobial,
                    "copies" => category == "common" ? 1 : 2, "valid_until" => valid_until&.iso8601 }.compact
        # Nulos do contrato §2 do 19d (não compactados; o canônico omite os nulos e a categoria comum).
        content.merge!("category" => category, "sncr" => nil, "patient_identification" => rules.payload[:patient_identification],
                       "prescriber_contact" => rules.payload[:prescriber_contact])
        # Uma vez por receita (esquema clinical-v1.1.0): a release do catálogo na emissão; null se só texto livre.
        content["catalog_release"] = rows.filter_map { |row| row[:catalog_release_id] }.first
        Result.ok(content: content, items: rows, antimicrobial: antimicrobial, category: category)
      end

      def item(entry, index, catalog, matcher, problems)
        entry = Input.object(entry)
        bad = ->(field) { Result.fail(:invalid_item, details: { index: index, field: field }) }
        reference = entry["catalog_item"].is_a?(Hash) ? entry["catalog_item"]["id"] : nil
        free = entry["free_text"].is_a?(String) ? entry["free_text"].squish : nil
        return bad.("catalog_item") if reference.nil? == free.nil?

        catalog_entry = nil
        if reference
          catalog_entry = catalog[reference.to_s]
          return bad.("catalog_item") unless catalog_entry && catalog_entry.status == "active" && !catalog_entry.hidden
        else
          return bad.("free_text") unless free.size.between?(3, 200)
        end
        quantity = decimal(entry["quantity"])
        return bad.("quantity") unless quantity && quantity.positive? && quantity <= 9999 && quantity.scale <= 2

        unit = Input.text(entry["quantity_unit"], 1..30)
        return bad.("quantity_unit") unless unit.is_a?(String)
        return bad.("route") unless PrescriptionItem::ROUTES.include?(entry["route"])

        dosage = Input.text(entry["dosage_instructions"], 3..500)
        return bad.("dosage_instructions") unless dosage.is_a?(String)

        duration = entry["duration_days"]
        return bad.("duration_days") unless duration.nil? || (duration.is_a?(Integer) && duration.between?(1, 365))
        return bad.("continuous") unless [ nil, true, false ].include?(entry["continuous"])

        reason = entry["reason_problem_id"]
        return bad.("reason_problem_id") unless reason.nil? || (reason.is_a?(String) && problems.include?(reason))

        flags = catalog_entry ? catalog_entry : matcher.scan(free)
        { catalog: catalog_entry, free_text: free, quantity: quantity, quantity_unit: unit, route: entry["route"],
          dosage_instructions: dosage, duration_days: duration, continuous: entry["continuous"] == true,
          reason_problem_id: reason, antimicrobial: flags.antimicrobial, controlled: flags.controlled,
          controlled_list: flags.controlled_list, anticonvulsant: flags.anticonvulsant == true }
      end

      def nursing(input, items, today, city_cnpj)
        items.each_with_index { |it, index| return Result.fail(:free_text_not_allowed, details: { index: index }) if it[:free_text] }
        version_id = input["nursing_protocol"].is_a?(Hash) ? input["nursing_protocol"]["version_id"].to_s : ""
        version = Uuid.valid?(version_id) ? NursingProtocolVersion.includes(:nursing_protocol, :items).find_by(id: version_id) : nil
        return Result.fail(:not_in_nursing_protocol) unless version && version.nursing_protocol.current_version(on: today)&.id == version.id

        allowed = version.items.index_by(&:catalog_item_id)
        items.each_with_index do |it, index|
          entry = allowed[it[:catalog].id]
          return Result.fail(:not_in_nursing_protocol, details: { index: index }) unless entry

          return Result.fail(:above_protocol_max_dose, details: { index: index }) if entry.max_quantity && !within_dose?(entry, it)

          it[:protocol_item] = entry
        end
        return Result.fail(:city_cnpj_missing) if city_cnpj.blank?

        version
      end

      # Unidade diferente (ou ausente) não dá para provar: conta como acima da dose.
      def within_dose?(entry, item)
        unit = entry.max_quantity_unit
        unit.present? && item[:quantity_unit].present? && unit.casecmp?(item[:quantity_unit]) && item[:quantity] <= entry.max_quantity
      end

      # Validade escolhida pelo prescritor só na receita comum (as outras têm validade fixa).
      def validity(input, today)
        return nil if input["valid_until"].nil?

        date = Input.date(input["valid_until"])
        date&.between?(today, today + MAX_VALIDITY_DAYS) ? date : Input.invalid("valid_until")
      end

      def rows(items)
        items.each_with_index.map do |it, index|
          entry = it[:catalog]
          { position: index + 1, medication_catalog_item_id: entry&.id, catmat_code: entry&.catmat_code,
            catalog_release_id: entry&.last_release_id, free_text: it[:free_text],
            printed_description: entry ? entry.label : it[:free_text], quantity: it[:quantity], quantity_unit: it[:quantity_unit],
            route: it[:route], dosage_instructions: it[:dosage_instructions], duration_days: it[:duration_days],
            continuous: it[:continuous], antimicrobial: it[:antimicrobial],
            nursing_protocol_version_item_id: it[:protocol_item]&.id, reason_problem_id: it[:reason_problem_id] }
        end
      end

      def content_item(row, it)
        { "position" => row[:position], "catalog_item" => it[:catalog] && Json.catalog_ref(it[:catalog]).deep_stringify_keys,
          "free_text" => row[:free_text], "printed_description" => row[:printed_description],
          "quantity" => Json.number(row[:quantity]), "quantity_unit" => row[:quantity_unit], "route" => row[:route],
          "dosage_instructions" => row[:dosage_instructions], "duration_days" => row[:duration_days],
          "continuous" => row[:continuous], "antimicrobial" => row[:antimicrobial],
          "reason_problem_id" => row[:reason_problem_id] }.compact
      end

      def protocol_json(version)
        protocol = version.nursing_protocol
        { "id" => protocol.id, "title" => protocol.title, "number" => protocol.number, "year" => protocol.year,
          "version_id" => version.id }
      end

      def decimal(value)
        return nil unless value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/\A\d+(\.\d+)?\z/))

        BigDecimal(value.to_s)
      end
      private_class_method :item, :nursing, :within_dose?, :validity, :rows, :content_item, :protocol_json, :decimal
    end
  end
end
