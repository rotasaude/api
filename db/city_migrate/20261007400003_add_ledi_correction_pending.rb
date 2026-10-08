# db/city_migrate/20261007400003_add_ledi_correction_pending.rb
# Módulo 19 (ADR 0031; spec §6): adendo que muda dado estruturado de uma
# ficha JÁ ACEITA vira uma linha correction_pending (com replaces_outbox_id =
# a aceita), que nunca é enviada até a regra de reenvio após aceite ser
# confirmada (api#41). O índice único por fonte passa a ignorá-la.
class AddLediCorrectionPending < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :ledi_outbox, name: "ck_ledi_outbox_status"
    add_check_constraint :ledi_outbox,
                         "status::text = ANY (ARRAY['pending'::text, 'sending'::text, 'accepted'::text, 'rejected'::text, 'failed'::text, 'correction_pending'::text])",
                         name: "ck_ledi_outbox_status"
    add_check_constraint :ledi_outbox, "status::text <> 'correction_pending'::text OR replaces_outbox_id IS NOT NULL",
                         name: "ck_ledi_outbox_correction"
    remove_index :ledi_outbox, name: "idx_ledi_outbox_source"
    add_index :ledi_outbox, %i[source_type source_id ficha_type], unique: true, name: "idx_ledi_outbox_source",
                                                                  where: "(status)::text <> ALL (ARRAY['rejected'::text, 'correction_pending'::text])"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
