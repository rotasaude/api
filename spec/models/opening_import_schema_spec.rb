require "rails_helper"
require Rails.root.join("db/city_migrate/20261125900004_add_opening_imports.rb").to_s

# Módulo 27b (Task 14; contrato §5; Q11; R23): a importação do saldo inicial e
# as linhas lidas. Nada some. A situação anda uploaded → validated → applied |
# discarded e applied → reverted, sempre com version + 1; o arquivo cifrado só
# vira NULL (no applied e no discarded) e nunca volta. A linha só ganha a
# entrada (de NULL a valor) ou passa de válida a erro.
RSpec.describe "Esquema da importação do saldo inicial (módulo 27b)", type: :model do
  before { pharmacy_city! }
  let(:user) { pharmacy_admin! }

  def import!(**over)
    OpeningImport.create!({ file_sha256: "a" * 64, file_data: "cnes;tipo_produto\n", uploaded_by_user: user }.merge(over))
  end

  def row!(import, **over)
    OpeningImportRow.create!({ opening_import: import, line: 2, cnes: "2384299", lote: "L-1", status: "valid", error_codes: [],
                               stock_location_id: central_location!.id, item_kind: "medication", catalog_item_id: losartana.id }.merge(over))
  end

  def validated!(import = import!)
    import.update_columns(status: "validated", rows_total: 1, rows_valid: 1, report: { "rows_valid" => 1 }, version: 2)
    import
  end

  def applied!(import = validated!)
    import.update_columns(status: "applied", file_data: nil, applied_at: Time.current, applied_by_user_id: user.id, version: 3)
    import
  end

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "a migração espelha os catálogos do código; irreversível" do
    expect([ AddOpeningImports::STATUSES, AddOpeningImports::ROW_STATUSES, AddOpeningImports::COLUMNS ])
      .to eq([ OpeningImport::STATUSES, OpeningImportRow::STATUSES, OpeningImports::Reader::HEADER ])
    expect { AddOpeningImports.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it "nasce uploaded na versão 1; outra situação no INSERT → trigger" do
    expect(import!.reload).to have_attributes(status: "uploaded", version: 1)
    refused(/opening_imports/) { import!(status: "validated") }
  end

  it "uploaded → validated → applied → reverted, cada passo com version + 1" do
    import = applied!
    import.update_columns(status: "reverted", reverted_at: Time.current, version: 4)
    expect(import.reload).to have_attributes(status: "reverted", version: 4, file_data: nil)
  end

  it "aplicar duas vezes → trigger" do
    import = applied!
    refused(/opening_imports/) { import.update_columns(status: "applied", version: 4) }
    refused(/opening_imports/) { import.update_columns(status: "validated", version: 4) }
  end

  it "transição sem version + 1 ou fora do caminho → trigger" do
    import = validated!
    refused(/version/) { import.update_columns(status: "applied", file_data: nil, applied_at: Time.current, applied_by_user_id: user.id) }
    refused(/opening_imports/) { import.update_columns(status: "reverted", reverted_at: Time.current, version: 3) }
    refused(/opening_imports/) { import!.update_columns(status: "applied", file_data: nil, applied_at: Time.current, applied_by_user_id: user.id, version: 2) }
  end

  it "o arquivo só vira NULL no applied e no discarded; `file_data` volta a ter valor → trigger" do
    import = validated!
    refused(/file_data/) { import.update_columns(file_data: nil, version: 3) }
    import.update_columns(status: "discarded", file_data: nil, version: 3)
    expect(import.reload.file_data).to be_nil

    applied = applied!
    refused(/file_data/) { applied.update_columns(status: "reverted", reverted_at: Time.current, file_data: "de volta", version: 4) }
  end

  it "a re-cifra regrava só o arquivo, sem versão" do
    import = validated!
    CityEncryption.allowing_reencryption { import.encrypt }
    expect(import.reload).to have_attributes(file_data: "cnes;tipo_produto\n", version: 2)
  end

  it "DELETE da importação e da linha → trigger" do
    import = validated!
    row = row!(import)
    refused(/opening_import_rows/) { row.delete }
    refused(/opening_imports/) { import.delete }
  end

  describe "opening_import_rows" do
    it "a linha ganha a entrada uma vez; válida vira erro; o resto não muda" do
      import = validated!
      row = row!(import)
      stocked_lot!(central_location!, item: amoxicilina)
      entry = StockEntry.find_by!(kind: "opening", stock_location_id: central_location!.id)
      row.update_columns(stock_entry_id: entry.id)
      expect(row.reload.stock_entry_id).to eq(entry.id)
      refused(/opening_import_rows/) { row.update_columns(stock_entry_id: nil) }
      refused(/opening_import_rows/) { row.update_columns(lote: "OUTRO") }

      other = row!(import, line: 3)
      other.update_columns(status: "error", error_codes: [ "opening_exists" ])
      refused(/opening_import_rows/) { other.update_columns(status: "valid", error_codes: []) }
    end

    it "erro sem código, código fora do formato ou válida sem item → CHECK" do
      import = validated!
      refused(/ck_opening_import_rows_status/) { row!(import, status: "error", error_codes: []) }
      refused(/ck_opening_import_rows_error_codes/) { row!(import, status: "error", error_codes: [ "Opening Exists" ]) }
      refused(/ck_opening_import_rows_item/) { row!(import, catalog_item_id: nil) }
      expect(row!(import, line: 4, status: "error", error_codes: [ "cnes_unknown" ], stock_location_id: nil, item_kind: nil, catalog_item_id: nil))
        .to be_persisted
    end
  end
end
