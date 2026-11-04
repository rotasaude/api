# Módulo 31 (contrato §12; ADR 0049): a SIGTAP da plataforma passa a guardar a
# quantidade máxima de execução, os dias de permanência e os atributos
# complementares (rl_procedimento_detalhe / CO_DETALHE) de cada procedimento,
# para a crítica das ações na hora. Nulo = sem limite (0 e 9999 do arquivo
# oficial viram nulo na leitura). Releases antigas ficam com nulo e sem
# atributos. A tabela nova é imutável pelo mesmo guard dos demais códigos
# (db/platform_triggers.sql). Irreversível.
class AddSigtapProcedureLimits < ActiveRecord::Migration[8.1]
  def up
    add_column :sigtap_procedures, :max_quantity, :integer
    add_column :sigtap_procedures, :max_stay_days, :integer
    add_check_constraint :sigtap_procedures,
                         "(max_quantity IS NULL OR max_quantity > 0) AND (max_stay_days IS NULL OR max_stay_days > 0)",
                         name: "ck_sigtap_procedures_limits"

    create_table :sigtap_procedure_attributes, force: :cascade do |t|
      t.uuid :release_id, null: false
      t.string :procedure_code, limit: 10, null: false
      t.string :attribute_code, limit: 3, null: false
      t.index %i[release_id procedure_code attribute_code], unique: true, name: "idx_sigtap_procedure_attributes_unique"
    end
    add_foreign_key :sigtap_procedure_attributes, :terminology_releases, column: :release_id

    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
