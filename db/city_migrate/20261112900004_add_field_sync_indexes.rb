# Módulo 24b (ADR 0052; contrato §9.3; Task 22, fix round 1 M1): índices do
# download do app de campo (FieldSync::Changes). O `t` do fluxo é calculado
# (GREATEST do cadastro com o paciente; do domicílio com famílias,
# responsáveis e os cadastros deles), então nenhum índice serve a ordem: só os
# filtros, sem varrer a cidade a cada página.
#   - individual_registrations (micro_area_id): o cadastro da microárea do escopo;
#   - individual_registrations (patient_id): os cadastros do responsável da
#     família, encerrados inclusive (os índices de patient_id que existem são
#     parciais: óbito e cadastro ativo);
#   - families (household_id): as famílias do domicílio, em mudança inclusive
#     (o único índice por domicílio é parcial: NOT moved_out).
# households já tem (micro_area_id, id). Só índice. Irreversível.
class AddFieldSyncIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :individual_registrations, :micro_area_id, name: "idx_individual_registrations_micro_area"
    add_index :individual_registrations, :patient_id, name: "idx_individual_registrations_patient"
    add_index :families, :household_id, name: "idx_families_household"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
