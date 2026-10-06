# Retratos mensais do CNES (ADR 0028; spec 2026-10-05 §5, §8): só municípios
# de cidades ativas, últimas 13 competências por município (retenção no
# gravador). CPF/CNS do profissional cifrados com a chave da plataforma (desvio
# 12); nenhum nome de profissional. Os filhos saem com o retrato (cascade).
class CreateCnesSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :cnes_snapshots, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :competence, null: false, limit: 6
      t.string :ibge_code, null: false, limit: 7
      t.datetime :imported_at, null: false
      t.timestamps
      t.index %i[ibge_code competence], unique: true, name: "idx_cnes_snapshots_municipality_competence"
      t.check_constraint "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text", name: "ck_cnes_snapshots_competence"
      t.check_constraint "ibge_code::text ~ '^[0-9]{7}$'::text", name: "ck_cnes_snapshots_ibge_code"
    end

    create_table :cnes_establishments do |t|
      t.uuid :snapshot_id, null: false
      t.string :cnes, null: false, limit: 7
      t.string :name, null: false
      t.string :unit_type, limit: 4
      t.index %i[snapshot_id cnes], unique: true
    end

    create_table :cnes_teams do |t|
      t.uuid :snapshot_id, null: false
      t.string :ine, null: false, limit: 10
      t.string :kind, null: false, limit: 4
      t.string :cnes, null: false, limit: 7
      t.string :name
      t.boolean :active, null: false
      t.index %i[snapshot_id ine], unique: true
    end

    create_table :cnes_professional_bonds do |t|
      t.uuid :snapshot_id, null: false
      t.string :cnes, null: false, limit: 7
      t.string :ine, limit: 10
      t.string :cbo_code, null: false, limit: 6
      t.text :cpf
      t.text :cns
      t.index :snapshot_id
    end

    %i[cnes_establishments cnes_teams cnes_professional_bonds].each do |table|
      add_foreign_key table, :cnes_snapshots, column: :snapshot_id, on_delete: :cascade
    end
  end
end
