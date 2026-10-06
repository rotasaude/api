# Fila de saída LEDI da cidade (ADR 0028; spec 2026-10-05 §6.3). Cada ficha
# entra já serializada (DadoTransporteThrift) e cifrada com a chave da cidade;
# o conteúdo é apagado quando o PEC aceita. Trigger em db/city_triggers.sql.
class CreateLediOutbox < ActiveRecord::Migration[8.1]
  def up
    create_table :ledi_outbox, id: :uuid do |t|
      t.string :uuid, limit: 44, null: false
      t.string :ficha_type, null: false
      t.string :competence, limit: 6, null: false
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :first_attempt_at
      t.string :last_error, limit: 500
      t.string :ledi_version, null: false
      t.text :payload
      t.datetime :accepted_at
      t.timestamps
    end
    add_index :ledi_outbox, :uuid, unique: true, name: "idx_ledi_outbox_uuid"
    add_index :ledi_outbox, %i[source_type source_id ficha_type], unique: true, name: "idx_ledi_outbox_source"
    add_index :ledi_outbox, %i[status next_attempt_at], name: "idx_ledi_outbox_due"
    add_index :ledi_outbox, %i[competence status], name: "idx_ledi_outbox_competence"
    add_check_constraint :ledi_outbox,
                         "status::text = ANY (ARRAY['pending'::text, 'sending'::text, 'accepted'::text, " \
                         "'rejected'::text, 'failed'::text])",
                         name: "ck_ledi_outbox_status"
    add_check_constraint :ledi_outbox, "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text",
                         name: "ck_ledi_outbox_competence"
    add_check_constraint :ledi_outbox, "ficha_type::text ~ '^[a-z_]+$'::text", name: "ck_ledi_outbox_ficha_type"
    add_check_constraint :ledi_outbox, "(status::text = 'accepted'::text) = (accepted_at IS NOT NULL)",
                         name: "ck_ledi_outbox_accepted_at"
    add_check_constraint :ledi_outbox, "status::text <> 'accepted'::text OR payload IS NULL",
                         name: "ck_ledi_outbox_accepted_payload"
    add_check_constraint :ledi_outbox, "status::text <> 'rejected'::text OR last_error IS NOT NULL",
                         name: "ck_ledi_outbox_rejected_error"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :ledi_outbox
    execute "DROP FUNCTION IF EXISTS rota_ledi_outbox_guard()"
  end
end
