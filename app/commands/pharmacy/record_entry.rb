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
# [ { path, error } ]` com todos (H8/H12), também as estruturais (`items`,
# `document.kind`, `document`): todo 422 traz `problems` com pelo menos um.
# `kind` é o do endpoint; o controlador manda nil quando `document.kind` do
# corpo não é invoice/donation. Nada é gravado se houver recusa,
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
#
# Módulo 29 (ADR 0047, Desvios 3–5; §15 V4, V18, V19): o domínio do local
# (Stock::Domain) decide a linha. Em local de vacina (rede de frio e sala) a
# linha é `{ "immunobiological_code", "manufacturer_key", "lot_number",
# "expires_on", "quantity"?, "package": { "units_per_package", "packages" } }`,
# em doses: `package` é obrigatório e `units_per_package` são as doses por
# frasco do catálogo (frascos fechados); `manufacturer_key` da lista do
# produto (`manufacturer_not_in_catalog`); código fora do catálogo →
# `immunobiological_unknown`. O lote grava a `manufacturer_key` e o nome do
# fabricante, nunca o código RNDS (V19). Linha de medicamento em local de vacina,
# ou de vacina em local de medicamento → `item_not_allowed_here` (path da
# linha, `items[i]`), sozinha na linha. O lote de vacina é único por (código,
# número); a abertura, por (local, código).
module Pharmacy
  module RecordEntry
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # Quantidade máxima de uma linha (NUMERIC(12,2) com CHECK <= 99999.99): a
    # embalagem só produz inteiros.
    MAX_QUANTITY = BigDecimal("99999.99")

    # Prefixo da chave de item do imunobiológico (o id do catálogo é uuid: nunca colide).
    IMMUNOBIOLOGICAL_KEY = "immunobiological:".freeze
    OPENING_INDEXES = %w[idx_stock_openings_once idx_stock_openings_immunobiological_once].freeze

    # Linha já validada: `item` (medicamento) OU `product` (imunobiológico, com
    # a `manufacturer_key`).
    Row = Struct.new(:index, :item, :product, :lot_number, :expires_on, :manufacturer, :manufacturer_key, :quantity, :package,
                     keyword_init: true) do
      def item_key = product ? "#{IMMUNOBIOLOGICAL_KEY}#{product.code}" : item.id
      def key = [ item_key, lot_number ]
      # O fabricante que precisa bater com o lote: a key na vacina, o nome no medicamento.
      def maker = product ? manufacturer_key : manufacturer
      def opening_path = "items[#{index}].#{product ? 'immunobiological_code' : 'catalog_item_id'}"
    end

    module_function

    # -> Result.ok(entry:, movements:) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(location:, kind:, document:, items:, by:, catalog:, now: Time.current)
      today = now.in_time_zone.to_date
      problems = kind == "opening" ? [] : document_problems(document, kind)
      unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_ENTRY_ITEMS)
        problems << problem("items", :invalid_request)
        return failure(problems)
      end

      rows, row_problems = validate_rows(items, catalog, today, Stock::Domain.for(location))
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
      raise unless OPENING_INDEXES.any? { |index| e.message.include?(index) }

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
    def document_problems(document, kind)
      return [ problem("document", :invalid_request) ] unless document.is_a?(Hash)

      found = []
      found << problem("document.kind", :invalid_request) unless Catalog::ENTRY_KINDS.include?(kind)
      number = document["number"]
      found << problem("document.number", :invalid_request) unless number.is_a?(String) && number.match?(Catalog::DOCUMENT_NUMBER)
      supplier = document["supplier"]
      found << problem("document.supplier", :invalid_request) unless supplier.is_a?(String) && supplier.strip.length.between?(1, Catalog::SUPPLIER_MAX)
      found
    end

    # -> [ [ Row ], [ problem ] ]. As linhas só valem sem problema algum.
    def validate_rows(items, catalog, today, domain)
      rows = []
      problems = []
      declared = {}
      items.each_with_index do |raw, index|
        next problems << problem("items[#{index}]", :invalid_request) unless raw.is_a?(Hash)

        row, found = validate_row(raw, index, catalog, today, domain)
        problems.concat(found)
        next unless row

        problems.concat(repeated_lot_problems(row, declared))
        rows << row
      end
      [ rows, problems ]
    end

    # -> [ Row | nil, [ problem ] ]
    def validate_row(raw, index, catalog, today, domain)
      prefix = "items[#{index}]"
      immunobiological = domain == Stock::Domain::IMMUNOBIOLOGICAL
      foreign = immunobiological ? raw["catalog_item_id"] : raw["immunobiological_code"]
      return [ nil, [ problem(prefix, :item_not_allowed_here) ] ] unless foreign.nil?

      return validate_immunobiological_row(raw, index, today) if immunobiological

      problems = []
      item = raw["catalog_item_id"].is_a?(String) ? catalog[raw["catalog_item_id"]] : nil
      item = nil unless item&.status == "active"
      problems << problem("#{prefix}.catalog_item_id", :invalid_item) unless item

      problems.concat(lot_problems(raw, prefix, today))
      lot_number = raw["lot_number"]
      expires_on = parse_date(raw["expires_on"])

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

    # Linha de vacina (§15 V4/V19): código do catálogo, fabricante pela key da
    # lista do produto, embalagem obrigatória com as doses por frasco do
    # catálogo. -> [ Row | nil, [ problem ] ]
    def validate_immunobiological_row(raw, index, today)
      prefix = "items[#{index}]"
      problems = []
      code = raw["immunobiological_code"]
      product = code.is_a?(String) ? Vaccination::Immunobiologicals.find(code) : nil
      problems << problem("#{prefix}.immunobiological_code", :immunobiological_unknown) unless product

      key = raw["manufacturer_key"]
      maker = product && key.is_a?(String) ? product.manufacturer(key) : nil
      problems << problem("#{prefix}.manufacturer_key", :manufacturer_not_in_catalog) if product && maker.nil?

      problems.concat(lot_problems(raw, prefix, today))

      quantity, package, quantity_problems = quantity_and_package(raw, prefix)
      problems.concat(quantity_problems)
      if raw["package"].nil?
        problems << problem("#{prefix}.package", :invalid_quantity)
      elsif package && product && package[:units_per_package] != product.doses_per_vial
        problems << problem("#{prefix}.package", :invalid_quantity)
      end
      return [ nil, problems.uniq ] if problems.any?

      [ Row.new(index: index, product: product, lot_number: raw["lot_number"], expires_on: parse_date(raw["expires_on"]),
                manufacturer: maker.name, manufacturer_key: maker.key, quantity: quantity, package: package), [] ]
    end

    # Número e validade do lote (comuns aos dois domínios). -> [ problem ]
    def lot_problems(raw, prefix, today)
      problems = []
      lot_number = raw["lot_number"]
      problems << problem("#{prefix}.lot_number", :invalid_request) unless lot_number.is_a?(String) && lot_number.match?(Catalog::LOT_NUMBER)

      expires_on = parse_date(raw["expires_on"])
      if expires_on.nil?
        problems << problem("#{prefix}.expires_on", :invalid_request)
      elsif expires_on < today
        problems << problem("#{prefix}.expires_on", :expired_lot)
      end
      problems
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

      clash = first.expires_on != row.expires_on || (row.maker && first.maker && row.maker != first.maker)
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

      medications, immunobiologicals = missing.partition(&:item)
      if medications.any?
        first_declared = medications.to_h { |row| [ row.key, rows.select { |other| other.key == row.key }.filter_map(&:manufacturer).first ] }
        StockLot.insert_all(medications.map do |row|
          { catalog_item_id: row.item.id, catmat_code: row.item.catmat_code, lot_number: row.lot_number, expires_on: row.expires_on,
            manufacturer: first_declared.fetch(row.key), dispensing_unit: DispensingUnit.for(row.item), created_by_user_id: by.id }
        end, unique_by: :idx_stock_lots_number)
      end
      if immunobiologicals.any?
        StockLot.insert_all(immunobiologicals.map do |row|
          { item_kind: Stock::Domain::IMMUNOBIOLOGICAL, immunobiological_code: row.product.code, lot_number: row.lot_number,
            expires_on: row.expires_on, manufacturer: row.manufacturer, manufacturer_key: row.manufacturer_key, dispensing_unit: "dose",
            created_by_user_id: by.id }
        end, unique_by: :idx_stock_lots_immunobiological_number)
      end
      find_lots(keys)
    end

    # Uma consulta por domínio: o produto cartesiano de itens × números é
    # filtrado por par.
    def find_lots(keys)
      return {} if keys.empty?

      codes, item_ids = keys.map(&:first).uniq.partition { |key| key.start_with?(IMMUNOBIOLOGICAL_KEY) }
      numbers = keys.map(&:last).uniq
      found = []
      found += StockLot.where(catalog_item_id: item_ids, lot_number: numbers).to_a if item_ids.any?
      found += StockLot.where(immunobiological_code: codes.map { |key| key.delete_prefix(IMMUNOBIOLOGICAL_KEY) }, lot_number: numbers).to_a if codes.any?
      found.index_by { |lot| lot_key(lot) }.slice(*keys)
    end

    def lot_key(lot)
      [ lot.immunobiological? ? "#{IMMUNOBIOLOGICAL_KEY}#{lot.immunobiological_code}" : lot.catalog_item_id, lot.lot_number ]
    end

    # Validade ou fabricante informado que diverge do lote gravado → lot_mismatch
    # (na vacina, a `manufacturer_key`; no medicamento, o nome, quando vem).
    def mismatch_problems(rows, lots)
      rows.filter_map do |row|
        lot = lots[row.key]
        next unless lot
        stored_maker = row.product ? lot.manufacturer_key : lot.manufacturer
        next unless lot.expires_on != row.expires_on || (row.maker && row.maker != stored_maker)

        problem("items[#{row.index}].lot_number", :lot_mismatch)
      end
    end

    # Itens da abertura que já têm abertura no local, uma recusa por linha.
    def opening_problems(location, rows)
      openings = StockOpening.where(stock_location_id: location.id)
      opened = openings.where(catalog_item_id: rows.filter_map { |row| row.item&.id }.uniq).pluck(:catalog_item_id).to_set
      opened += openings.where(immunobiological_code: rows.filter_map { |row| row.product&.code }.uniq)
                        .pluck(:immunobiological_code).map { |code| "#{IMMUNOBIOLOGICAL_KEY}#{code}" }
      rows.select { |row| opened.include?(row.item_key) }.map { |row| problem(row.opening_path, :opening_exists) }
    end

    def mark_openings(location, entry, rows)
      rows.uniq(&:item_key).sort_by(&:item_key).each do |row|
        StockOpening.create!(stock_location: location, catalog_item_id: row.item&.id, immunobiological_code: row.product&.code, stock_entry: entry)
      end
    end

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :persist, :write, :document_problems, :validate_rows, :validate_row, :validate_immunobiological_row, :lot_problems,
                         :quantity_and_package, :package_product, :parse_date, :repeated_lot_problems, :stored_lot_problems, :merge_by_line,
                         :ensure_lots, :find_lots, :lot_key, :mismatch_problems, :opening_problems, :mark_openings, :problem, :failure
  end
end
