# Plataforma do 19d (ADR 0034): marca de anticonvulsivante no catálogo (o
# limite de 180 dias da Portaria 344, art. 59), o tipo anticonvulsant nas
# listas Anvisa e a última conversa com o SNCR (real e simulado). O nome do
# CHECK de kind das listas é o conferido na Task 0 (Step 6).
class AddControlledPrescriptionsPlatform < ActiveRecord::Migration[8.1]
  def up
    add_column :medication_catalog_items, :anticonvulsant, :boolean, null: false, default: false
    add_column :anvisa_list_releases, :anticonvulsants_count, :integer, null: false, default: 0

    remove_check_constraint :anvisa_list_substances, name: "ck_anvisa_list_substances_kind"
    add_check_constraint :anvisa_list_substances,
                         "kind::text = ANY (ARRAY['antimicrobial'::text, 'controlled'::text, 'anticonvulsant'::text])",
                         name: "ck_anvisa_list_substances_kind"

    create_table :sncr_checks, id: :uuid do |t|
      t.string :target, null: false
      t.datetime :last_check_at, null: false
      t.boolean :last_check_ok, null: false
    end
    add_index :sncr_checks, :target, unique: true
    add_check_constraint :sncr_checks, "target::text = ANY (ARRAY['real'::text, 'simulated'::text])", name: "ck_sncr_checks_target"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
