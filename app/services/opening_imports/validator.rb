# Conferência da planilha do saldo inicial, linha a linha (módulo 27b;
# contrato §5; Valor 11; Q13, Q15, Q21, Q26; R7, R9, R24). Lê o banco (locais,
# catálogo, produtos, aberturas, apresentações do OBM), nunca grava.
#
# `rows` vêm do Reader. `usable_domains` (R24) e `required_domains` (Q26: os
# domínios com o envio à BNAFAR ligado, `Bnafar::Gate.domains`) são lidos pelo
# chamador FORA da transação da cidade.
#
# Por linha:
#   - local pelo CNES (`StockLocation#bnafar_cnes`, ativo) e pelo domínio do
#     `tipo_produto` (o mesmo CNES serve à farmácia e à sala de vacina da
#     unidade): sem local com o CNES → `cnes_unknown`; com o CNES, mas sem
#     local do domínio → `item_not_allowed_here`; domínio inutilizável →
#     `domain_disabled`;
#   - item pelo `codigo_produto`: CATMAT ativo no catálogo (medicamento),
#     código do YAML (vacina) ou `code` do produto ativo (vetorial); senão
#     `product_unknown`;
#   - `quantidade` inteira, na unidade BNAFAR (frasco na vacina): a quantidade
#     do estoque é `Bnafar::Units.from_bnafar` (doses na vacina, R7);
#   - campos do lote pelo `Bnafar::LotFields.parse` (a mesma regra da
#     entrada): exigidos só nos `required_domains` (Q26); fora deles, a linha
#     válida sem algum campo do envio só leva o aviso `send_fields_missing`;
#   - vacina (Q21): o `cnpj_fabricante` só resolve a `manufacturer_key` do
#     YAML (`manufacturer_not_in_catalog`); o CNPJ nunca vai ao lote;
#   - `ampp_not_in_vmp` (Q36): o AMPP existe no OBM, mas é de outro VMP;
#     `ampp_unknown` só para o AMPP fora do catálogo;
#   - `cnpj_fabricante` vazio passa mesmo com o envio ligado (Q38) e conta no
#     aviso `send_fields_missing`;
#   - `lot_mismatch` (Q37, regra da Q7): o mesmo lote (item + número), em
#     qualquer local, com validade, `manufacturer_key` ou campo BNAFAR
#     preenchido (menos o preço) divergente entre as linhas (todas viram erro)
#     ou do lote já gravado;
#   - `duplicate_line` (o mesmo lote do mesmo item no mesmo local outra vez),
#     `opening_exists` (abertura ativa do item no local, R9) e
#     `too_many_lots` (mais de 100 lotes de um item num local: a entrada não
#     parte os lotes de um item, Catalog::MAX_ENTRY_ITEMS).
# Uma linha junta todos os seus códigos (CODES, na ordem das colunas).
module OpeningImports
  module Validator
    CODES = %w[cnes_unknown invalid_product_type product_unknown item_not_allowed_here domain_disabled invalid_lot_number invalid_date
               expired_lot invalid_quantity invalid_price invalid_cnpj invalid_anvisa program_unknown ampp_unknown ampp_not_in_vmp anvisa_mismatch
               manufacturer_not_in_catalog lot_mismatch duplicate_line opening_exists too_many_lots].freeze
    PRODUCT_TYPES = { "medicamento" => Stock::Domain::MEDICATION, "vacina" => Stock::Domain::IMMUNOBIOLOGICAL,
                      "vetorial" => Stock::Domain::VECTOR_CONTROL }.freeze
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    INTEGER = /\A\d{1,9}\z/
    # Vírgula decimal (até 2 casas), ponto de milhar opcional: 1.234,56 | 1234,5 | 7.
    PRICE = /\A(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d{1,2}))?\z/
    # Campo do LotFields → código da linha.
    FIELD_CODES = { "unit_price_cents" => "invalid_price", "manufacturer_cnpj" => "invalid_cnpj", "manufacturer" => "invalid_cnpj",
                    "manufacturer_international" => "invalid_cnpj", "anvisa_registration" => "invalid_anvisa",
                    "health_program" => "program_unknown", "ampp_code" => "ampp_unknown" }.freeze

    RowResult = Data.define(:line, :fields, :status, :error_codes, :stock_location_id, :item_kind, :catalog_item_id, :immunobiological_code,
                            :vector_product_id, :manufacturer_key, :quantity, :value_cents, :send_fields_missing)

    module_function

    # -> [ RowResult ] na ordem das linhas
    def call(rows:, today:, usable_domains:, required_domains:)
      facts = Facts.new(rows)
      drafts = rows.map { |row| draft(row, today, facts, usable_domains.to_set, required_domains.to_set) }
      flag_duplicates(drafts)
      flag_lot_conflicts(drafts, facts)
      flag_openings(drafts, facts)
      flag_too_many_lots(drafts)
      drafts.map { |draft| finish(draft) }
    end

    # Código de recusa de um campo do LotFields (`error` vindo dele).
    def field_code(field, error)
      return error.to_s if %w[anvisa_mismatch ampp_not_in_vmp].include?(error.to_s)

      FIELD_CODES.fetch(field.to_s.split(".").last, error.to_s)
    end

    # "1.234,56" → 123456; nil se o formato não é o da planilha.
    def price_cents(text)
      match = text.is_a?(String) ? PRICE.match(text) : nil
      return nil unless match

      (match[1].delete(".").to_i * 100) + match[2].to_s.ljust(2, "0").to_i
    end

    # Linha da RecordEntry (chaves String) a partir das colunas lidas, para o
    # Apply. `row` responde às onze colunas e ao que foi resolvido.
    def entry_item(row)
      item = { "lot_number" => row.lote, "expires_on" => row.validade }
      case row.item_kind
      when Stock::Domain::IMMUNOBIOLOGICAL
        product = Vaccination::Immunobiologicals.find(row.immunobiological_code)
        item.merge!("immunobiological_code" => row.immunobiological_code, "manufacturer_key" => row.manufacturer_key,
                    "package" => { "units_per_package" => product.doses_per_vial, "packages" => Integer(row.quantidade, 10) })
      when Stock::Domain::VECTOR_CONTROL
        item.merge!("vector_product_id" => row.vector_product_id, "quantity" => Integer(row.quantidade, 10).to_s)
      else
        item.merge!("catalog_item_id" => row.catalog_item_id, "quantity" => Integer(row.quantidade, 10).to_s)
      end
      item.merge(bnafar_raw(row.attributes.symbolize_keys.slice(*Reader::COLUMNS), row.item_kind)).compact
    end

    # Fatos lidos de uma vez para todas as linhas.
    class Facts
      attr_reader :locations_by_cnes

      def initialize(rows)
        @locations_by_cnes = StockLocation.active_locations.includes(:health_unit).to_a.group_by(&:bnafar_cnes).except(nil)
        codes = rows.filter_map { |row| row[:codigo_produto] if PRODUCT_TYPES[row[:tipo_produto].to_s.downcase] == Stock::Domain::MEDICATION }
        catmats = codes.select { |code| code.match?(INTEGER) }.map(&:to_i).uniq
        @catalog = catmats.empty? ? {} : MedicationCatalogItem.where(catmat_code: catmats, status: "active").index_by(&:catmat_code)
        vector_codes = rows.filter_map { |row| row[:codigo_produto]&.downcase if row[:tipo_produto].to_s.downcase == "vetorial" }.uniq
        @vector = vector_codes.empty? ? {} : VectorProduct.where(active: true).where("lower(code) IN (?)", vector_codes).index_by { |p| p.code.downcase }
      end

      def location(cnes, domain)
        candidates = @locations_by_cnes.fetch(cnes, [])
        return [ nil, :unknown ] if candidates.empty?

        found = candidates.select { |location| Stock::Domain.for(location) == domain }.min_by(&:id)
        found ? [ found, nil ] : [ nil, :other_domain ]
      end

      def medication(code) = code.to_s.match?(INTEGER) ? @catalog[code.to_i] : nil

      # Lotes já gravados para as chaves [chave de item, número] -> { chave => StockLot }.
      def stored_lots(keys)
        return {} if keys.empty?

        numbers = keys.map(&:last).uniq
        by_kind = keys.map(&:first).uniq.group_by { |key| key.split(":", 2).first }.transform_values { |list| list.map { |key| key.split(":", 2).last } }
        found = []
        found += StockLot.where(catalog_item_id: by_kind[Stock::Domain::MEDICATION], lot_number: numbers).to_a if by_kind[Stock::Domain::MEDICATION]
        found += StockLot.where(immunobiological_code: by_kind[Stock::Domain::IMMUNOBIOLOGICAL], lot_number: numbers).to_a if by_kind[Stock::Domain::IMMUNOBIOLOGICAL]
        found += StockLot.where(vector_product_id: by_kind[Stock::Domain::VECTOR_CONTROL], lot_number: numbers).to_a if by_kind[Stock::Domain::VECTOR_CONTROL]
        found.index_by { |lot| [ item_key(lot.catalog_item_id, lot.immunobiological_code, lot.vector_product_id), lot.lot_number ] }.slice(*keys)
      end
      def vector(code) = code && @vector[code.downcase]

      # Pares (local, chave de item) com abertura ativa (R9).
      def opened(location_ids)
        return Set.new if location_ids.empty?

        StockOpening.active.where(stock_location_id: location_ids).pluck(:stock_location_id, :catalog_item_id, :immunobiological_code, :vector_product_id)
                    .to_set { |location_id, item_id, code, vector_id| [ location_id, item_key(item_id, code, vector_id) ] }
      end

      def self.item_key(item_id, code, vector_id)
        return "#{Stock::Domain::IMMUNOBIOLOGICAL}:#{code}" if code
        return "#{Stock::Domain::VECTOR_CONTROL}:#{vector_id}" if vector_id

        "#{Stock::Domain::MEDICATION}:#{item_id}"
      end

      def item_key(...) = self.class.item_key(...)
    end

    # ---- por linha -----------------------------------------------------------

    def draft(row, today, facts, usable, required)
      codes = []
      domain = PRODUCT_TYPES[row[:tipo_produto].to_s.downcase]
      location, missing = row[:cnes].to_s.match?(::Bnafar::Catalog::CNES) ? facts.location(row[:cnes], domain) : [ nil, :unknown ]
      codes << "cnes_unknown" if missing == :unknown
      codes << "invalid_product_type" unless domain
      location = nil unless domain
      resolved = domain ? resolve_item(row, domain, facts) : {}
      codes << "product_unknown" if domain && resolved.empty?
      codes << "item_not_allowed_here" if domain && missing == :other_domain
      codes << "domain_disabled" if location && !usable.include?(domain)

      codes << "invalid_lot_number" unless row[:lote].is_a?(String) && row[:lote].match?(Pharmacy::Catalog::LOT_NUMBER)
      codes.concat(date_codes(row[:validade], today))
      quantity = quantity_of(row[:quantidade], domain, resolved[:product])
      codes << "invalid_quantity" unless quantity

      fields, field_codes = lot_fields(row, domain, resolved, required.include?(domain))
      codes.concat(field_codes)
      manufacturer = manufacturer_of(row, resolved[:product]) if domain == Stock::Domain::IMMUNOBIOLOGICAL
      codes << "manufacturer_not_in_catalog" if resolved[:product] && manufacturer.nil?

      { row: row, codes: codes, stock_domain: domain, location: location, resolved: resolved, manufacturer: manufacturer, quantity: quantity,
        fields: fields, required: required.include?(domain) }
    end

    # -> { catalog_item: } | { product: } | { vector_product: } | {}
    def resolve_item(row, domain, facts)
      code = row[:codigo_produto]
      case domain
      when Stock::Domain::IMMUNOBIOLOGICAL
        product = code && Vaccination::Immunobiologicals.find(code)
        product ? { product: product } : {}
      when Stock::Domain::VECTOR_CONTROL
        found = facts.vector(code)
        found ? { vector_product: found } : {}
      else
        found = facts.medication(code)
        found ? { catalog_item: found } : {}
      end
    end

    def date_codes(text, today)
      date = text.is_a?(String) && text.match?(ISO_DATE) ? Date.iso8601(text) : nil
      return [ "invalid_date" ] unless date
      return [ "expired_lot" ] if date < today

      []
    rescue Date::Error
      [ "invalid_date" ]
    end

    # Quantidade do estoque (BigDecimal) ou nil. Vacina: frascos × doses por
    # frasco, frascos em PACKAGE_RANGE; o resto: até o teto da linha.
    def quantity_of(text, domain, product)
      return nil unless text.is_a?(String) && text.match?(INTEGER)

      count = text.to_i
      return nil unless count.positive?

      if domain == Stock::Domain::IMMUNOBIOLOGICAL
        return nil unless Pharmacy::Catalog::PACKAGE_RANGE.cover?(count)
        return BigDecimal(count) unless product # o código já falhou; a conta da dose não vale

        quantity = ::Bnafar::Units.from_bnafar(product, count)
      else
        quantity = BigDecimal(count)
      end
      quantity <= Pharmacy::Catalog::MAX_QUANTITY ? quantity : nil
    end

    # -> [ { coluna => valor }, [ código ] ]
    def lot_fields(row, domain, resolved, required)
      codes = []
      raw = bnafar_raw(row, domain)
      if row[:valor_unitario] && price_cents(row[:valor_unitario]).nil?
        codes << "invalid_price"
        raw.delete("unit_price_cents")
      end
      vmp = resolved[:product]&.obm_vmp || resolved[:catalog_item]&.vmp_code
      fields, problems = ::Bnafar::LotFields.parse(raw, prefix: "", stock_domain: domain || Stock::Domain::MEDICATION, required: required,
                                                        vmp_code: vmp)
      # Q38: o CNPJ vazio passa mesmo com o envio ligado (o lote nasce sem
      # fabricante, `lot_incomplete`; o internacional entra pelo complemento).
      problems = problems.reject { |found| found[:path] == "manufacturer_cnpj" && found[:error] == "required" }
      codes.concat(problems.map { |found| field_code(found[:path], found[:error]) })
      [ fields, codes.uniq ]
    end

    # Corpo do LotFields a partir das colunas (a vacina não leva CNPJ, Q21).
    def bnafar_raw(row, domain)
      raw = { "unit_price_cents" => price_cents(row[:valor_unitario]), "anvisa_registration" => row[:registro_anvisa],
              "health_program" => row[:programa], "ampp_code" => row[:ampp] }
      raw["manufacturer_cnpj"] = row[:cnpj_fabricante] unless domain == Stock::Domain::IMMUNOBIOLOGICAL
      raw
    end

    def manufacturer_of(row, product)
      return nil unless product && row[:cnpj_fabricante]

      Vaccination::Immunobiologicals.manufacturer_by_cnpj(product, row[:cnpj_fabricante])
    end

    # ---- entre linhas --------------------------------------------------------

    def item_key_of(draft)
      resolved = draft[:resolved]
      Facts.item_key(resolved[:catalog_item]&.id, resolved[:product]&.code, resolved[:vector_product]&.id)
    end

    def keyed(drafts) = drafts.select { |draft| draft[:location] && draft[:resolved].any? }

    def flag_duplicates(drafts)
      seen = Set.new
      keyed(drafts).each do |draft|
        key = [ draft[:location].id, item_key_of(draft), draft[:row][:lote] ]
        draft[:codes] << "duplicate_line" unless seen.add?(key)
      end
    end

    # Q37 (regra da Q7): o mesmo lote (item + número) em qualquer local não
    # diverge entre as linhas nem do lote já gravado na cidade, salvo o preço.
    # (a) linhas divergentes entre si → todas as do lote; (b) linha divergente
    # do gravado → ela.
    def flag_lot_conflicts(drafts, facts)
      lotted = drafts.select { |draft| draft[:resolved].any? && draft[:row][:lote].is_a?(String) }
      groups = lotted.group_by { |draft| [ item_key_of(draft), draft[:row][:lote] ] }
      stored = facts.stored_lots(groups.keys)
      groups.each do |key, group|
        signatures = group.map { |draft| lot_signature(draft) }
        clash = signatures.combination(2).any? { |one, other| ::Bnafar::LotFields.conflict?(one, other) }
        group.each { |draft| draft[:codes] << "lot_mismatch" } if clash
        lot = stored[key]
        next unless lot

        group.each { |draft| draft[:codes] << "lot_mismatch" if diverges?(lot, draft) }
      end
    end

    # O que precisa bater no lote: validade, a `manufacturer_key` (vacina) e os campos BNAFAR preenchidos, menos o preço.
    def lot_signature(draft)
      signature = draft[:fields].except(:unit_price_cents)
      expires = parse_date(draft[:row][:validade])
      signature[:expires_on] = expires if expires
      signature[:manufacturer_key] = draft[:manufacturer].key if draft[:manufacturer]
      signature
    end

    def diverges?(lot, draft)
      expires = parse_date(draft[:row][:validade])
      return true if expires && expires != lot.expires_on
      return true if draft[:manufacturer] && draft[:manufacturer].key != lot.manufacturer_key

      ::Bnafar::LotFields.diff(lot, draft[:fields].except(:unit_price_cents)).last.any?
    end

    def parse_date(text)
      text.is_a?(String) && text.match?(ISO_DATE) ? Date.iso8601(text) : nil
    rescue Date::Error
      nil
    end

    def flag_openings(drafts, facts)
      candidates = keyed(drafts)
      opened = facts.opened(candidates.map { |draft| draft[:location].id }.uniq)
      candidates.each { |draft| draft[:codes] << "opening_exists" if opened.include?([ draft[:location].id, item_key_of(draft) ]) }
    end

    def flag_too_many_lots(drafts)
      groups = keyed(drafts).reject { |draft| draft[:codes].include?("duplicate_line") }.group_by { |draft| [ draft[:location].id, item_key_of(draft) ] }
      groups.each_value do |group|
        next if group.map { |draft| draft[:row][:lote] }.uniq.size <= Pharmacy::Catalog::MAX_ENTRY_ITEMS

        group.each { |draft| draft[:codes] << "too_many_lots" }
      end
    end

    def finish(draft)
      row = draft[:row]
      codes = draft[:codes].uniq
      resolved = draft[:resolved]
      price = draft[:fields][:unit_price_cents]
      count = row[:quantidade].to_i if draft[:quantity]
      RowResult.new(line: row[:line], fields: row.slice(*Reader::COLUMNS), status: codes.empty? ? "valid" : "error", error_codes: codes,
                    stock_location_id: draft[:location]&.id, item_kind: (draft[:stock_domain] if resolved.any?),
                    catalog_item_id: resolved[:catalog_item]&.id, immunobiological_code: resolved[:product]&.code,
                    vector_product_id: resolved[:vector_product]&.id, manufacturer_key: draft[:manufacturer]&.key,
                    quantity: draft[:quantity], value_cents: (price && count ? price * count : nil),
                    send_fields_missing: codes.empty? && send_fields_missing?(draft))
    end

    # A linha não traz algum campo do envio (o lote vai aparecer como `lot_incomplete`, Q22).
    def send_fields_missing?(draft)
      fields = draft[:fields]
      resolved = draft[:resolved]
      vmp = resolved[:product]&.obm_vmp || resolved[:catalog_item]&.vmp_code
      missing = fields[:unit_price_cents].nil? || fields[:anvisa_registration].nil? || fields[:health_program].nil?
      missing ||= fields[:manufacturer_cnpj].nil? unless draft[:stock_domain] == Stock::Domain::IMMUNOBIOLOGICAL
      missing ||= vmp.present? && fields[:ampp_code].nil? unless draft[:stock_domain] == Stock::Domain::VECTOR_CONTROL
      missing
    end

    private_class_method :draft, :resolve_item, :date_codes, :quantity_of, :lot_fields, :bnafar_raw, :manufacturer_of, :item_key_of, :keyed,
                         :flag_duplicates, :flag_lot_conflicts, :lot_signature, :diverges?, :parse_date, :flag_openings, :flag_too_many_lots, :finish, :send_fields_missing?
  end
end
