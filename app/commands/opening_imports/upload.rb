# Envio da planilha do saldo inicial (módulo 27b; contrato §5; Q11, Q26; R24):
# lê (Reader), confere (Validator) e grava a importação `validated` com as
# linhas e o relatório. Nada toca o estoque (Review Focus 5): só o `apply`.
#
# `usable_domains` e `required_domains` são lidos pelo chamador FORA da
# transação da cidade (interruptores). O arquivo fica cifrado em `file_data`
# até o apply ou o discard; a resposta nunca o devolve.
module OpeningImports
  module Upload
    BATCH = 1_000

    module_function

    # -> Result.ok(import:) | fail(:invalid_file | :file_too_large, details: { path: "file_base64" })
    def call(bytes:, by:, usable_domains:, required_domains:, now: Time.current)
      read = Reader.call(bytes)
      return read if read.failure?

      today = now.in_time_zone.to_date
      results = Validator.call(rows: read.payload.fetch(:rows), today: today, usable_domains: usable_domains, required_domains: required_domains)
      import = OpeningImport.transaction do
        created = OpeningImport.create!(file_sha256: Digest::SHA256.hexdigest(bytes), file_data: bytes.dup.force_encoding(Encoding::UTF_8),
                                        uploaded_by_user: by, created_at: now, updated_at: now)
        results.each_slice(BATCH) { |slice| OpeningImportRow.insert_all!(slice.map { |result| row_attributes(created, result, now) }) }
        created.update!(status: "validated", rows_total: results.size, rows_valid: results.count { |result| result.status == "valid" },
                        report: Report.snapshot(created), version: created.version + 1)
        created
      end
      Result.ok(import: import)
    end

    def row_attributes(import, result, now)
      result.fields.merge(opening_import_id: import.id, line: result.line, status: result.status, error_codes: result.error_codes,
                          stock_location_id: result.stock_location_id, item_kind: result.item_kind, catalog_item_id: result.catalog_item_id,
                          immunobiological_code: result.immunobiological_code, vector_product_id: result.vector_product_id,
                          manufacturer_key: result.manufacturer_key, send_fields_missing: result.send_fields_missing, created_at: now)
    end

    private_class_method :row_attributes
  end
end
