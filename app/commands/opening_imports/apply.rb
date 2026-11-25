# Aplicação da importação conferida (módulo 27b; contrato §5; Q11; R7, R9):
# as linhas válidas viram entradas `opening` pelo Pharmacy::RecordEntry, com
# quem aplicou como autor (Q11: o usuário da cidade, nunca o mantenedor) e
# `bnafar_required: false` (os campos do envio já foram exigidos na
# conferência, Q26).
#
# Por local, numa transação cada (ordem fixa por id do local): entradas de até
# Catalog::MAX_ENTRY_ITEMS linhas que nunca partem os lotes de um item (o
# `too_many_lots` da conferência garante que um item cabe numa entrada). A
# linha que o RecordEntry recusa (o item ganhou abertura depois da
# conferência, o lote venceu, o local foi desativado…) vira `error` com o
# código, e o resto da entrada vai de novo. Vacina: `package` com as doses
# por frasco do YAML e os frascos da planilha, mais a `manufacturer_key` (R7).
#
# Concorrência: cada transação de local trava a importação (FOR UPDATE, antes
# de qualquer lote: importação → produtos → lotes → local) e confere a
# situação e a versão; só pega linhas válidas ainda sem entrada. Duas
# aplicações ao mesmo tempo se revezam local a local sem repetir linha, e a
# segunda termina em `opening_import_changed`. A aplicação interrompida no
# meio fica `validated` e retoma de onde parou.
#
# No fim: `applied`, `file_data` NULL, `applied_at` (o `now` do início: o
# desfazer conta o movimento criado depois dele), relatório refeito, version
# + 1 e o evento `opening_import.applied` só com ids.
module OpeningImports
  module Apply
    # Recusa do RecordEntry (erro) → código da linha (o resto fica com o código
    # do RecordEntry, como `lot_mismatch`).
    ENTRY_CODES = { "invalid_item" => "product_unknown", "immunobiological_unknown" => "product_unknown", "location_inactive" => "cnes_unknown" }.freeze
    INDEX = /\Aitems\[(\d+)\](?:\.(\w+))?/

    class Changed < StandardError; end

    module_function

    # -> Result.ok(import:) | fail(:expected_version_required | :opening_import_changed)
    def call(import:, expected_version:, by:, now: Time.current)
      return Changes.version_required unless expected_version.is_a?(Integer)

      current = OpeningImport.select(:id, :status, :version).find(import.id)
      return Changes.changed unless current.status == "validated" && current.version == expected_version

      catalog = catalog_for(current)
      location_ids = pending(current).distinct.order(:stock_location_id).pluck(:stock_location_id)
      location_ids.each { |location_id| apply_location(current, expected_version, location_id, by, catalog, now) }
      finish(current, expected_version, by, now)
    rescue Changed
      Changes.changed
    end

    def pending(import) = OpeningImportRow.where(opening_import_id: import.id, status: "valid", stock_entry_id: nil)

    # Itens do catálogo da plataforma, lidos FORA das transações da cidade.
    def catalog_for(import)
      ids = pending(import).where.not(catalog_item_id: nil).distinct.pluck(:catalog_item_id)
      ids.empty? ? {} : MedicationCatalogItem.where(id: ids).index_by(&:id)
    end

    def apply_location(import, version, location_id, by, catalog, now)
      OpeningImport.transaction do
        lock!(import, version, slim: true)
        location = StockLocation.find(location_id)
        rows = pending(import).where(stock_location_id: location_id).order(:line).to_a
        chunks(rows).each { |chunk| record(location, chunk, by, catalog, now) }
      end
    end

    # FOR UPDATE na importação; `slim` não lê o arquivo cifrado (até ~7 MB) a cada local.
    def lock!(import, version, slim: false)
      scope = slim ? OpeningImport.select(:id, :status, :version) : OpeningImport
      locked = scope.lock.find(import.id)
      raise Changed unless locked.status == "validated" && locked.version == version

      locked
    end

    # Grupos por item, inteiros, empacotados em ordem até o teto da entrada.
    def chunks(rows)
      groups = rows.group_by { |row| [ row.item_kind, row.catalog_item_id || row.immunobiological_code || row.vector_product_id ] }
                   .sort_by { |key, _group| key.map(&:to_s) }.map(&:last)
      groups.each_with_object([ [] ]) do |group, packed|
        packed << [] if packed.last.size + group.size > Pharmacy::Catalog::MAX_ENTRY_ITEMS
        packed.last.concat(group)
      end.reject(&:empty?)
    end

    # Uma entrada; a recusa marca as linhas e a entrada vai de novo sem elas.
    def record(location, chunk, by, catalog, now)
      until chunk.empty?
        result = Pharmacy::RecordEntry.call(location: location, kind: "opening", document: nil, items: chunk.map { |row| Validator.entry_item(row) },
                                            by: by, catalog: catalog, now: now, bnafar_required: false)
        if result.ok?
          OpeningImportRow.where(id: chunk.map(&:id)).update_all(stock_entry_id: result.payload.fetch(:entry).id) # rubocop:disable Rails/SkipsModelValidations
          return
        end

        failed = refused_rows(result, chunk)
        failed.each { |row, codes| OpeningImportRow.where(id: row.id).update_all(status: "error", error_codes: codes) } # rubocop:disable Rails/SkipsModelValidations
        chunk -= failed.keys
      end
    end

    # -> { row => [ código ] }. Recusa sem linha (o local) vale para todas.
    def refused_rows(result, chunk)
      problems = Array(result.details[:problems])
      by_row = problems.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |found, acc|
        match = INDEX.match(found[:path].to_s)
        row = match && chunk[match[1].to_i]
        acc[row] << code_for(found[:error], match[2]) if row
      end
      return by_row.transform_values(&:uniq) if by_row.any?

      code = ENTRY_CODES.fetch(result.reason.to_s, result.reason.to_s)
      chunk.to_h { |row| [ row, [ code ] ] }
    end

    def code_for(error, field)
      error = error.to_s
      return ENTRY_CODES.fetch(error) if ENTRY_CODES.key?(error)
      return Validator.field_code(field, error) if field && Validator::FIELD_CODES.key?(field)
      return "invalid_date" if field == "expires_on" && error == "invalid_request"
      return "invalid_lot_number" if field == "lot_number" && error == "invalid_request"

      error
    end

    def finish(import, version, by, now)
      OpeningImport.transaction do
        locked = lock!(import, version)
        valid = OpeningImportRow.where(opening_import_id: locked.id, status: "valid").count
        locked.update!(status: "applied", file_data: nil, applied_at: now, applied_by_user: by, rows_valid: valid,
                       report: Report.snapshot(locked), version: locked.version + 1)
        DomainEvents.publish("opening_import.applied", opening_import_id: locked.id, user_id: by.id)
        Result.ok(import: locked)
      end
    end

    private_class_method :pending, :catalog_for, :apply_location, :lock!, :chunks, :record, :refused_rows, :code_for, :finish
  end
end
