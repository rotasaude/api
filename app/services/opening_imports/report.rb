# Relatório da importação do saldo inicial (módulo 27b; contrato §5; Q26).
#
# `snapshot(import)` lê as linhas gravadas e devolve o que fica em
# `opening_imports.report` (jsonb): só códigos, contagens, ids de local e
# códigos de produto, nunca nome nem o conteúdo do arquivo. Roda na
# conferência e de novo na aplicação (linhas que viraram erro).
# `call(import)` é a forma das respostas: o snapshot com o nome e o tipo dos
# locais lidos agora.
#
# - `quantity` na unidade do estoque (doses na vacina, `Bnafar::Units.from_bnafar`, R7);
# - `value_cents` = quantidade da planilha (unidade BNAFAR) × `valor_unitario`;
# - `rows_missing_send_fields`: linhas válidas sem algum campo do envio, só aviso (Q26).
module OpeningImports
  module Report
    FIELDS = %i[status error_codes stock_location_id item_kind immunobiological_code tipo_produto codigo_produto quantidade valor_unitario
                send_fields_missing].freeze

    module_function

    def snapshot(import)
      rows = OpeningImportRow.where(opening_import_id: import.id).pluck(*FIELDS).map { |values| FIELDS.zip(values).to_h }
      valid, errors = rows.partition { |row| row[:status] == "valid" }
      { "rows_valid" => valid.size, "rows_error" => errors.size,
        "errors_by_code" => errors.flat_map { |row| row[:error_codes] }.tally.sort.to_h,
        "rows_missing_send_fields" => valid.count { |row| row[:send_fields_missing] },
        "products_without_catalog" => errors.select { |row| row[:error_codes].include?("product_unknown") }
                                            .map { |row| { "tipo_produto" => row[:tipo_produto], "codigo_produto" => row[:codigo_produto] } }
                                            .uniq.sort_by { |product| product.values.map(&:to_s) },
        "locations_without_cnes" => StockLocation.active_locations.includes(:health_unit).to_a.reject(&:bnafar_cnes).map(&:id).sort,
        "totals_by_location" => totals(valid) }
    end

    def call(import)
      report = import.report
      ids = report.fetch("totals_by_location", []).map { |total| total["stock_location_id"] } + report.fetch("locations_without_cnes", [])
      locations = StockLocation.where(id: ids.uniq).index_by(&:id)
      report.except("locations_without_cnes", "totals_by_location").merge(
        "locations_without_cnes" => report.fetch("locations_without_cnes", []).filter_map do |id|
          location = locations[id]
          { "id" => id, "name" => location.name, "kind" => location.kind } if location
        end,
        "totals_by_location" => report.fetch("totals_by_location", []).map do |total|
          total.slice("stock_location_id").merge("location_name" => locations[total["stock_location_id"]]&.name)
               .merge(total.slice("rows", "quantity", "value_cents"))
        end
      )
    end

    def totals(valid)
      valid.group_by { |row| row[:stock_location_id] }.sort_by { |id, _rows| id }.map do |id, group|
        { "stock_location_id" => id, "rows" => group.size,
          "quantity" => Pharmacy::Quantity.dump(group.sum { |row| stock_quantity(row) }),
          "value_cents" => group.sum { |row| (Validator.price_cents(row[:valor_unitario]) || 0) * row[:quantidade].to_i } }
      end
    end

    def stock_quantity(row)
      return BigDecimal(row[:quantidade].to_i) unless row[:item_kind] == Stock::Domain::IMMUNOBIOLOGICAL

      ::Bnafar::Units.from_bnafar(Vaccination::Immunobiologicals.find(row[:immunobiological_code]), row[:quantidade].to_i)
    end

    private_class_method :totals, :stock_quantity
  end
end
