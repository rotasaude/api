# Módulo 27b (BNAFAR; plano, Task 14; contrato §5; Q11, Q20; R23): o saldo
# inicial pela planilha conferida pela própria cidade.
#   - opening_imports: a importação, com o arquivo cifrado (CityEncryption;
#     apagado ao aplicar ou descartar), as contagens, o relatório (só códigos,
#     contagens, ids de local e códigos de produto), quem enviou e quem
#     aplicou. Situação uploaded → validated → applied | discarded e
#     applied → reverted, sempre com version + 1 (concorrência otimista);
#   - opening_import_rows: as onze colunas lidas como texto, o local e o item
#     resolvidos, a situação da linha (valid | error) com os códigos e a
#     entrada `opening` que a linha gerou (é ela que marca a abertura como
#     "da planilha" em GET /pharmacy/openings).
# Triggers em db/city_triggers.sql (bloco "Módulo 27b — importação"; o dump
# não representa trigger). Irreversível.
class AddOpeningImports < ActiveRecord::Migration[8.1]
  # Espelhos de OpeningImport::STATUSES, OpeningImportRow::STATUSES e
  # OpeningImports::Reader::HEADER no dia desta migração (a migração não lê
  # código da aplicação).
  STATUSES = %w[uploaded validated applied discarded reverted].freeze
  ROW_STATUSES = %w[valid error].freeze
  ITEM_KINDS = %w[medication immunobiological vector_control].freeze
  COLUMNS = %w[cnes tipo_produto codigo_produto ampp lote validade quantidade valor_unitario cnpj_fabricante registro_anvisa
               programa].freeze
  MAX_ROWS = 20_000

  def up
    create_imports
    create_rows

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_imports
    create_table :opening_imports, id: :uuid do |t|
      t.string :status, null: false, default: "uploaded"
      t.string :file_sha256, null: false, limit: 64
      t.text :file_data
      t.integer :rows_total, null: false, default: 0
      t.integer :rows_valid, null: false, default: 0
      t.jsonb :report, null: false, default: {}
      t.references :uploaded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :applied_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :applied_at
      t.datetime :reverted_at
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :opening_imports, %i[created_at id], name: "idx_opening_imports_created"
    add_check_constraint :opening_imports, "status::text = ANY (ARRAY[#{quoted(STATUSES)}])", name: "ck_opening_imports_status"
    add_check_constraint :opening_imports, "file_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "ck_opening_imports_sha256"
    add_check_constraint :opening_imports, "version >= 1", name: "ck_opening_imports_version"
    add_check_constraint :opening_imports, "rows_total >= 0 AND rows_total <= #{MAX_ROWS} AND rows_valid >= 0 AND rows_valid <= rows_total",
                         name: "ck_opening_imports_rows"
    add_check_constraint :opening_imports, "(file_data IS NOT NULL) = (status::text = ANY (ARRAY['uploaded'::text, 'validated'::text]))",
                         name: "ck_opening_imports_file"
    add_check_constraint :opening_imports,
                         "(applied_at IS NOT NULL) = (status::text = ANY (ARRAY['applied'::text, 'reverted'::text])) AND " \
                         "(applied_by_user_id IS NOT NULL) = (applied_at IS NOT NULL) AND " \
                         "(reverted_at IS NOT NULL) = (status::text = 'reverted'::text)",
                         name: "ck_opening_imports_dates"
  end

  def create_rows
    create_table :opening_import_rows, id: :uuid do |t|
      t.references :opening_import, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :line, null: false
      COLUMNS.each { |column| t.text column }
      t.references :stock_location, type: :uuid, foreign_key: true, index: false
      t.string :item_kind
      # Item do catálogo da plataforma (sem FK, como em stock_lots).
      t.uuid :catalog_item_id
      t.string :immunobiological_code, limit: 10
      t.references :vector_product, type: :uuid, foreign_key: true, index: false
      t.string :manufacturer_key, limit: 40
      t.string :status, null: false
      t.text :error_codes, array: true, null: false, default: []
      # Aviso (Q26): a linha válida sem os campos do envio, num domínio fora do envio.
      t.boolean :send_fields_missing, null: false, default: false
      t.references :stock_entry, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :opening_import_rows, %i[opening_import_id line], unique: true, name: "idx_opening_import_rows_line"
    add_index :opening_import_rows, :stock_entry_id, where: "stock_entry_id IS NOT NULL", name: "idx_opening_import_rows_entry"
    add_check_constraint :opening_import_rows, "line >= 2", name: "ck_opening_import_rows_line"
    add_check_constraint :opening_import_rows,
                         "status::text = ANY (ARRAY[#{quoted(ROW_STATUSES)}]) AND (status::text = 'error'::text) = (cardinality(error_codes) > 0) AND " \
                         "(stock_entry_id IS NULL OR status::text = 'valid'::text)",
                         name: "ck_opening_import_rows_status"
    add_check_constraint :opening_import_rows,
                         "array_position(error_codes, NULL::text) IS NULL AND " \
                         "array_to_string(error_codes, ','::text) ~ '^([a-z_]{2,40}(,[a-z_]{2,40})*)?$'::text",
                         name: "ck_opening_import_rows_error_codes"
    add_check_constraint :opening_import_rows,
                         "(item_kind IS NULL OR item_kind::text = ANY (ARRAY[#{quoted(ITEM_KINDS)}])) AND " \
                         "num_nonnulls(catalog_item_id, immunobiological_code, vector_product_id) <= 1 AND " \
                         "(status::text = 'error'::text OR (stock_location_id IS NOT NULL AND item_kind IS NOT NULL AND " \
                         "(catalog_item_id IS NOT NULL) = (item_kind::text = 'medication'::text) AND " \
                         "(immunobiological_code IS NOT NULL) = (item_kind::text = 'immunobiological'::text) AND " \
                         "(vector_product_id IS NOT NULL) = (item_kind::text = 'vector_control'::text) AND " \
                         "(manufacturer_key IS NOT NULL) = (item_kind::text = 'immunobiological'::text)))",
                         name: "ck_opening_import_rows_item"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
end
