# Descarte da importação conferida e não aplicada (módulo 27b; contrato §5;
# Q20): `discarded`, o arquivo apagado, version + 1. A importação com alguma
# linha já aplicada (aplicação interrompida no meio) não se descarta.
module OpeningImports
  module Discard
    module_function

    # -> Result.ok(import:) | fail(:expected_version_required | :opening_import_changed)
    def call(import:, expected_version:, by:)
      return Changes.version_required unless expected_version.is_a?(Integer)

      OpeningImport.transaction do
        locked = OpeningImport.lock.find(import.id)
        partly_applied = OpeningImportRow.where(opening_import_id: locked.id).where.not(stock_entry_id: nil).exists?
        next Changes.changed if locked.status != "validated" || locked.version != expected_version || partly_applied

        locked.update!(status: "discarded", file_data: nil, version: locked.version + 1)
        Result.ok(import: locked)
      end
    end
  end
end
