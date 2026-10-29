# Entrada de estoque num local (ADR 0045; plano do api, Desvios 1, 4 e 5):
# nota (`invoice`), doação (`donation`) ou inventário de abertura (`opening`).
#
# `items` é a lista de linhas `{ "catalog_item_id", "lot_number", "expires_on",
# "manufacturer"?, "quantity"?, "package"?: { "units_per_package", "packages" } }`
# com chaves String (é o que o controlador entrega). `catalog` é
# `{ catalog_item_id => MedicationCatalogItem }`, lido FORA da transação: o item
# precisa estar `active`; `hidden` vale (o catálogo esconde da busca, não do
# estoque). `document` (`number`, `supplier`) vale na nota e na doação; a
# abertura o ignora.
#
# Quantidade: com `package`, é `units_per_package × packages` (inteiros 1..10000,
# produto até 99999,99); com `quantity` junto, os dois têm de bater. Sem
# `package`, só `quantity` (String como no papel, Pharmacy::Quantity). Nunca
# arredonda.
#
# Todas as recusas voltam de uma vez: `error`/`path` do primeiro e `problems:
# [ { path, error } ]` com todos (H8/H12). Nada é gravado se houver recusa,
# inclusive o lote que a tentativa criou: tudo numa transação que volta.
#
# Ordem de travas (a do módulo, veja Pharmacy::Ledger): lotes → local.
#   1. lotes novos nascem em ordem fixa de (item, número), por INSERT ... ON
#      CONFLICT DO NOTHING no índice único idx_stock_lots_number: quem perde a
#      corrida espera o outro commitar e relê o lote dele. Ordem fixa evita que
#      duas notas com os mesmos lotes novos em ordem inversa se esperem;
#   2. lock_lots! — FOR UPDATE em TODOS os lotes da escrita, em ordem de id,
#      antes de qualquer movimento (o INSERT em stock_movements pede FOR KEY SHARE
#      no lote);
#   3. lock_location! — FOR SHARE no local;
#   4. StockEntry → StockOpening por item (abertura) → um movimento por linha.
# A abertura valendo uma vez por (local, item) é do índice único
# idx_stock_openings_once: a corrida de duas aberturas vira opening_exists.
#
# Evento `stock_receipt.recorded` só com ids (stock_entry_id, user_id).
module Pharmacy
  module RecordEntry
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # Quantidade máxima de uma linha (NUMERIC(12,2) com CHECK <= 99999.99): a
    # embalagem só produz inteiros.
    MAX_QUANTITY = BigDecimal("99999.99")

    # Linha já validada.
    Row = Struct.new(:index, :item, :lot_number, :expires_on, :manufacturer, :quantity, :package, keyword_init: true) do
      def key = [ item.id, lot_number ]
    end

    module_function

    # -> Result.ok(entry:, movements:) | fail(:invalid_request, details: { path: }) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(location:, kind:, document:, items:, by:, catalog:, now: Time.current)
      return Result.fail(:invalid_request, details: { path: "document.kind" }) unless Catalog::ENTRY_KINDS.include?(kind)

      today = now.in_time_zone.to_date
      problems = kind == "opening" ? [] : document_problems(document)
      unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_ENTRY_ITEMS)
        problems << problem("items", :invalid_request)
        return problems.one? ? structure_failure("items") : failure(problems)
      end

      rows, row_problems = validate_rows(items, catalog, today)
      problems += merge_by_line(row_problems, stored_lot_problems(rows))
      return failure(problems) if problems.any?

      persist(location: location, kind: kind, document: document, rows: rows, by: by, now: now)
    end

    def persist(location:, kind:, document:, rows:, by:, now:)
      result = nil
      StockEntry.transaction(requires_new: true) do
        result = write(location: location, kind: kind, document: document, rows: rows, by: by, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_stock_openings_once")

      # Outra abertura do mesmo item no local commitou primeiro; a transação já voltou.
      problems = opening_problems(location, rows)
      raise if problems.empty?

      failure(problems)
    end

    def write(location:, kind:, document:, rows:, by:, now:)
      lots = ensure_lots(rows, by)
      mismatches = mismatch_problems(rows, lots)
      return failure(mismatches) if mismatches.any?

      Ledger.lock_lots!(lots.values.map(&:id).sort)
      Ledger.lock_location!(location.id)

      if kind == "opening"
        existing = opening_problems(location, rows)
        return failure(existing) if existing.any?
      end

      entry = StockEntry.create!(stock_location: location, kind: kind, recorded_by_user: by, created_at: now,
                                 document_number: (document["number"] if kind != "opening"),
                                 supplier: (document["supplier"].strip if kind != "opening"))
      mark_openings(location, entry, rows) if kind == "opening"
      movements = rows.map do |row|
        Ledger.record!(location: location, lot: lots.fetch(row.key), kind: Catalog::ENTRY_MOVEMENT.fetch(kind), quantity: row.quantity,
                       by: by, document: entry, package: row.package, at: now)
      end
      DomainEvents.publish("stock_receipt.recorded", stock_entry_id: entry.id, user_id: by.id)
      Result.ok(entry: entry, movements: movements)
    rescue Ledger::Inactive
      Result.fail(:location_inactive)
    end

    # ---- validação (sem banco, fora da transação) --------------------------

    # -> [ { path:, error: } ]
    def document_problems(document)
      return [ problem("document", :invalid_request) ] unless document.is_a?(Hash)

      found = []
      number = document["number"]
      found << problem("document.number", :invalid_request) unless number.is_a?(String) && number.match?(Catalog::DOCUMENT_NUMBER)
      supplier = document["supplier"]
      found << problem("document.supplier", :invalid_request) unless supplier.is_a?(String) && supplier.strip.length.between?(1, Catalog::SUPPLIER_MAX)
      found
    end

    # -> [ [ Row ], [ problem ] ]. As linhas só valem sem problema algum.
    def validate_rows(items, catalog, today)
      rows = []
      problems = []
      declared = {}
      items.each_with_index do |raw, index|
        next problems << problem("items[#{index}]", :invalid_request) unless raw.is_a?(Hash)

        row, found = validate_row(raw, index, catalog, today)
        problems.concat(found)
        next unless row

        problems.concat(repeated_lot_problems(row, declared))
        rows << row
      end
      [ rows, problems ]
    end

    # -> [ Row | nil, [ problem ] ]
    def validate_row(raw, index, catalog, today)
      prefix = "items[#{index}]"
      problems = []

      item = raw["catalog_item_id"].is_a?(String) ? catalog[raw["catalog_item_id"]] : nil
      item = nil unless item&.status == "active"
      problems << problem("#{prefix}.catalog_item_id", :invalid_item) unless item

      lot_number = raw["lot_number"]
      problems << problem("#{prefix}.lot_number", :invalid_request) unless lot_number.is_a?(String) && lot_number.match?(Catalog::LOT_NUMBER)

      expires_on = parse_date(raw["expires_on"])
      if expires_on.nil?
        problems << problem("#{prefix}.expires_on", :invalid_request)
      elsif expires_on < today
        problems << problem("#{prefix}.expires_on", :expired_lot)
      end

      manufacturer = raw["manufacturer"]
      if manufacturer.nil?
        nil
      elsif manufacturer.is_a?(String) && manufacturer.strip.length <= Catalog::MANUFACTURER_MAX
        manufacturer = manufacturer.strip.presence
      else
        problems << problem("#{prefix}.manufacturer", :invalid_request)
      end

      quantity, package, quantity_problems = quantity_and_package(raw, prefix)
      problems.concat(quantity_problems)
      return [ nil, problems ] if problems.any?

      [ Row.new(index: index, item: item, lot_number: lot_number, expires_on: expires_on, manufacturer: manufacturer,
                quantity: quantity, package: package), [] ]
    end

    # Desvio 4. -> [ BigDecimal | nil, { units_per_package:, packages: } | nil, [ problem ] ]
    def quantity_and_package(raw, prefix)
      problems = []
      package = raw["package"]
      package_given = !package.nil?
      product = package_given ? package_product(package) : nil
      if package_given && product.nil?
        problems << problem("#{prefix}.package", :invalid_quantity)
        package = nil
      elsif package_given
        package = { units_per_package: package["units_per_package"], packages: package["packages"] }
      end

      declared = raw["quantity"]
      quantity = declared.nil? ? product : Quantity.parse(declared)
      # Embalagem recusada já foi dita: não somar uma quantidade "ausente".
      refused = quantity.nil? ? !(declared.nil? && package_given) : (product && quantity != product)
      problems << problem("#{prefix}.quantity", :invalid_quantity) if refused
      [ quantity, package, problems ]
    end

    # units_per_package × packages, ou nil quando não é um objeto com dois
    # inteiros em 1..10000 ou o produto passa do teto da coluna.
    def package_product(package)
      return nil unless package.is_a?(Hash)

      per = package["units_per_package"]
      count = package["packages"]
      return nil unless [ per, count ].all? { |value| value.is_a?(Integer) && Catalog::PACKAGE_RANGE.cover?(value) }

      product = BigDecimal(per * count)
      product <= MAX_QUANTITY ? product : nil
    end

    def parse_date(raw)
      return nil unless raw.is_a?(String) && raw.match?(ISO_DATE)

      Date.iso8601(raw)
    rescue Date::Error
      nil
    end

    # O mesmo (item, número) duas vezes no pedido, com validade ou fabricante
    # diferentes entre si, é lot_mismatch na segunda linha.
    def repeated_lot_problems(row, declared)
      first = declared[row.key]
      unless first
        declared[row.key] = row
        return []
      end

      clash = first.expires_on != row.expires_on || (row.manufacturer && first.manufacturer && row.manufacturer != first.manufacturer)
      clash ? [ problem("items[#{row.index}].lot_number", :lot_mismatch) ] : []
    end

    # O lote gravado é imutável: a divergência com ele vale sem trava, sobre as
    # linhas válidas, mesmo quando outra linha já falhou (todas as recusas de
    # uma vez). Dentro da transação o `write` confere de novo (a corrida).
    def stored_lot_problems(rows)
      return [] if rows.empty?

      mismatch_problems(rows, find_lots(rows.map(&:key).uniq))
    end

    # Recusas na ordem das linhas (as de campo e as do lote gravado; uma linha
    # só tem as do lote quando é válida), sem repetir path + erro.
    def merge_by_line(row_problems, stored)
      (row_problems + stored).uniq.each_with_index.sort_by { |found, position| [ found[:path][/\Aitems\[(\d+)\]/, 1].to_i, position ] }.map(&:first)
    end

    # ---- lotes e abertura (com banco, dentro da transação) -----------------

    # Lotes por (item, número): os que já existem, e os que faltam criados em
    # ordem fixa. -> { [item_id, lot_number] => StockLot }
    def ensure_lots(rows, by)
      keys = rows.map(&:key).uniq
      lots = find_lots(keys)
      missing = rows.uniq(&:key).reject { |row| lots.key?(row.key) }.sort_by(&:key)
      return lots if missing.empty?

      # Antes de gravar, as divergências com o que já existe (imutável) valem.
      return lots if mismatch_problems(rows, lots).any?

      first_declared = missing.to_h { |row| [ row.key, rows.select { |other| other.key == row.key }.filter_map(&:manufacturer).first ] }
      StockLot.insert_all(missing.map do |row|
        { catalog_item_id: row.item.id, catmat_code: row.item.catmat_code, lot_number: row.lot_number, expires_on: row.expires_on,
          manufacturer: first_declared.fetch(row.key), dispensing_unit: DispensingUnit.for(row.item), created_by_user_id: by.id }
      end, unique_by: :idx_stock_lots_number)
      find_lots(keys)
    end

    # Uma consulta: o produto cartesiano de itens × números é filtrado por par.
    def find_lots(keys)
      return {} if keys.empty?

      StockLot.where(catalog_item_id: keys.map(&:first).uniq, lot_number: keys.map(&:last).uniq).to_a
              .select { |lot| keys.include?([ lot.catalog_item_id, lot.lot_number ]) }
              .index_by { |lot| [ lot.catalog_item_id, lot.lot_number ] }
    end

    # Validade ou fabricante informado que diverge do lote gravado → lot_mismatch.
    def mismatch_problems(rows, lots)
      rows.filter_map do |row|
        lot = lots[row.key]
        next unless lot
        next unless lot.expires_on != row.expires_on || (row.manufacturer && row.manufacturer != lot.manufacturer)

        problem("items[#{row.index}].lot_number", :lot_mismatch)
      end
    end

    # Itens da abertura que já têm abertura no local, uma recusa por linha.
    def opening_problems(location, rows)
      opened = StockOpening.where(stock_location_id: location.id, catalog_item_id: rows.map { |row| row.item.id }.uniq).pluck(:catalog_item_id).to_set
      rows.select { |row| opened.include?(row.item.id) }.map { |row| problem("items[#{row.index}].catalog_item_id", :opening_exists) }
    end

    def mark_openings(location, entry, rows)
      rows.map { |row| row.item.id }.uniq.sort.each do |item_id|
        StockOpening.create!(stock_location: location, catalog_item_id: item_id, stock_entry: entry)
      end
    end

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def structure_failure(path) = Result.fail(:invalid_request, details: { path: path })

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :persist, :write, :document_problems, :validate_rows, :validate_row, :quantity_and_package, :package_product,
                         :parse_date, :repeated_lot_problems, :stored_lot_problems, :merge_by_line, :ensure_lots, :find_lots, :mismatch_problems, :opening_problems,
                         :mark_openings, :problem, :structure_failure, :failure
  end
end
