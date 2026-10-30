# Substitui a lista de estoque mínimo de um local (ADR 0045; contrato §3).
# `rows`: lista de até `MAX_MINIMUM_ROWS` (500) `{ "catalog_item_id", "minimum" }`
# (mais que isso → `invalid_request` `path: "minimums"`); o item precisa estar ATIVO
# no catálogo da plataforma e não pode se repetir; `minimum` é a quantidade como
# no papel (String com ponto, até 2 casas; "0" vale e desliga o alerta).
#
# O mínimo nunca é apagado (trigger): "substituir" é gravar os da lista e levar
# a 0 os que sobraram no local. Por isso o GET só mostra os maiores que zero.
#
# Todas as recusas voltam de uma vez: `error`/`path` do primeiro e
# `problems: [ { path, error } ]` com todos (`minimums[i].catalog_item_id`,
# `minimums[i].minimum`, `minimums[i]`). Nada é gravado se houver recusa.
# Evento `pharmacy.settings_changed` (subject `minimums`) só com ids, e só
# quando a lista efetiva muda.
module Pharmacy
  module SaveMinimums
    module_function

    # -> Result.ok(changed:) | fail(:invalid_request, details: { path: "minimums", problems: [ … ] }) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] }).
    def call(location:, rows:, by:)
      unless rows.is_a?(Array) && rows.size <= Catalog::MAX_MINIMUM_ROWS
        return Result.fail(:invalid_request, details: { path: "minimums", problems: [ problem("minimums", :invalid_request) ] })
      end

      wanted, problems = validate(rows)
      if problems.any?
        first = problems.first
        return Result.fail(first[:error], details: { path: first[:path], problems: problems })
      end

      StockMinimum.transaction(requires_new: true) do
        # Duas trocas da lista do mesmo local não se misturam.
        StockLocation.lock.find(location.id)
        changed = replace(location, wanted, by)
        DomainEvents.publish("pharmacy.settings_changed", subject: "minimums", stock_location_id: location.id, user_id: by.id) if changed
        Result.ok(changed: changed)
      end
    end

    # -> [{ item_id => BigDecimal }, problems]
    def validate(rows)
      candidates = rows.filter_map { |row| row["catalog_item_id"] if row.is_a?(Hash) && row["catalog_item_id"].is_a?(String) }.uniq
      active = MedicationCatalogItem.where(id: candidates, status: "active").pluck(:id).to_set
      wanted = {}
      problems = []
      rows.each_with_index do |row, index|
        next problems << problem("minimums[#{index}]", :invalid_request) unless row.is_a?(Hash)

        item_id = row["catalog_item_id"]
        if !item_id.is_a?(String) || !active.include?(item_id)
          problems << problem("minimums[#{index}].catalog_item_id", :invalid_item)
        elsif wanted.key?(item_id)
          problems << problem("minimums[#{index}].catalog_item_id", :invalid_request)
        end
        minimum = Quantity.parse(row["minimum"], allow_zero: true)
        problems << problem("minimums[#{index}].minimum", :invalid_quantity) if minimum.nil?
        wanted[item_id] = minimum if item_id.is_a?(String) && active.include?(item_id) && minimum && !wanted.key?(item_id)
      end
      [ wanted, problems ]
    end

    # Grava a lista pedida e leva a 0 o que sobrou. -> true quando a lista
    # efetiva (os maiores que zero) mudou.
    def replace(location, wanted, by)
      current = StockMinimum.where(stock_location_id: location.id).pluck(:catalog_item_id, :minimum).to_h
      before = current.select { |_id, value| value.positive? }
      after = wanted.select { |_id, value| value.positive? }
      return false if before == after

      now = Time.current
      rows = wanted.filter_map do |item_id, minimum|
        next if current[item_id] == minimum || (current[item_id].nil? && minimum.zero?)

        { stock_location_id: location.id, catalog_item_id: item_id, minimum: minimum, updated_by_user_id: by.id }
      end
      StockMinimum.upsert_all(rows, unique_by: :idx_stock_minimums_item) if rows.any?
      dropped = before.keys - wanted.keys
      StockMinimum.where(stock_location_id: location.id, catalog_item_id: dropped)
                  .update_all(minimum: 0, updated_by_user_id: by.id, updated_at: now) if dropped.any?
      true
    end

    def problem(path, error) = { path: path, error: error.to_s }

    private_class_method :validate, :replace, :problem
  end
end
