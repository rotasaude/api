# app/commands/nursing_protocols/save.rb
# Protocolos municipais de enfermagem (COFEN 801/2026; ADR 0033; contrato §6).
# Criar = cabeçalho + versão 1; editar = versão nova (número seguinte, com o
# protocolo travado). Itens: do catálogo da plataforma (lido FORA da
# transação pelo chamador), ativos, não escondidos e nunca controlados; dose
# máxima opcional = quantidade máxima por item de receita (Desvio 10).
module NursingProtocols
  module Save
    MAX_ITEMS = 100

    module_function

    def catalog_ids(params)
      Array(params["items"]).filter_map { |item| item.is_a?(Hash) && item["catalog_item_id"].to_s.match?(ClinicalDocuments::BaseController::UUID) ? item["catalog_item_id"] : nil }
    end

    def create(params:, by:, catalog:, today: Time.zone.today)
      title = params["title"].is_a?(String) ? params["title"].squish : ""
      number = params["number"].is_a?(String) ? params["number"].squish : ""
      year = params["year"]
      return invalid("title") unless title.size.between?(3, 200)
      return invalid("number") unless number.size.between?(1, 30)
      return invalid("year") unless year.is_a?(Integer) && year.between?(1990, today.year + 1)

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        protocol = NursingProtocol.create!(title: title, number: number, year: year, created_by_user_id: by.id)
        result = version!(protocol, params, by, catalog, 1)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_exists)
    end

    def add_version(protocol:, params:, by:, catalog:)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        protocol.lock!
        result = version!(protocol, params, by, catalog, protocol.versions.maximum(:version).to_i + 1)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def version!(protocol, params, by, catalog, number)
      valid_from = ClinicalDocuments::IsoDate.parse(params["valid_from"])
      return invalid("valid_from") unless valid_from

      valid_until = params["valid_until"].nil? ? nil : ClinicalDocuments::IsoDate.parse(params["valid_until"])
      return invalid("valid_until") if !params["valid_until"].nil? && (valid_until.nil? || valid_until < valid_from)

      items = params["items"]
      return invalid("items") unless items.is_a?(Array) && items.size.between?(1, MAX_ITEMS)

      rows = []
      items.each_with_index do |item, index|
        row = item_row(item, index, catalog, rows)
        return row if row.is_a?(Result)

        rows << row
      end
      version = NursingProtocolVersion.create!(nursing_protocol: protocol, version: number, valid_from: valid_from,
                                               valid_until: valid_until, created_by_user_id: by.id)
      rows.each { |row| NursingProtocolVersionItem.create!(row.merge(nursing_protocol_version: version)) }
      Result.ok(protocol: protocol)
    end

    def item_row(item, index, catalog, rows)
      bad = ->(field) { Result.fail(:invalid_item, details: { index: index, field: field }) }
      return bad.("catalog_item_id") unless item.is_a?(Hash)

      entry = catalog[item["catalog_item_id"].to_s]
      return bad.("catalog_item_id") unless entry && entry.status == "active" && !entry.hidden
      return Result.fail(:controlled_not_allowed, details: { index: index }) if entry.controlled
      return bad.("catalog_item_id") if rows.any? { |row| row[:catalog_item_id] == entry.id }

      max = item["max_dose"]
      return { catalog_item_id: entry.id } if max.nil?

      quantity = max.is_a?(Hash) && max["quantity"].is_a?(Numeric) ? BigDecimal(max["quantity"].to_s) : nil
      unit = max.is_a?(Hash) && max["unit"].is_a?(String) ? max["unit"].squish : ""
      return bad.("max_dose") unless quantity && quantity.positive? && quantity <= 9999 && unit.size.between?(1, 30)

      { catalog_item_id: entry.id, max_quantity: quantity, max_quantity_unit: unit }
    end

    def invalid(field) = Result.fail(:invalid_content, details: { field: field })
    private_class_method :version!, :item_row, :invalid
  end
end
