# Módulo 32a (ADR 0050, R4; contrato §1 e §14 Q4/Q5; plano, Desvios 4–6):
# o paciente provisório da UPA — quem chega sem documento nem nome. Ganha
# `unidentified` (bool em claro: o `no_cpf_reason` é cifrado não
# determinístico e não se busca por ele; índice parcial, Q4), a descrição
# cifrada (`unidentified_description`) e a marca da fusão (`merged_into_id`):
# identificado como um paciente que já existe, tudo o que é do provisório
# passa ao real e o provisório fica, fundido, sem nada apagado.
# Os triggers (db/city_triggers.sql, executado no fim) seguram a fusão: o
# rota_patient_guard (provisório nunca volta; merged_into uma vez, só para um
# identificado) e a rota_patient_merge_ok, chamada no topo de cada guarda que
# recusa trocar o paciente, sob a marca rota.patient_merge. Irreversível.
class AddUrgencyPatients < ActiveRecord::Migration[8.1]
  def up
    add_column :patients, :unidentified, :boolean, null: false, default: false
    add_column :patients, :unidentified_description, :text
    add_reference :patients, :merged_into, type: :uuid, foreign_key: { to_table: :patients }, index: true
    add_index :patients, :unidentified, where: "unidentified", name: "idx_patients_unidentified"
    add_check_constraint :patients, "NOT unidentified OR (cpf IS NULL AND cns IS NULL)", name: "ck_patients_unidentified"
    add_check_constraint :patients, "merged_into_id IS NULL OR (unidentified AND merged_into_id <> id)", name: "ck_patients_merged"
    add_check_constraint :patients, "NOT unidentified OR unidentified_description IS NOT NULL", name: "ck_patients_description"
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
