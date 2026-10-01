# ADR 0026: pedido de exclusão (Art. 18). O pedido é a prova da resposta da
# cidade: só acréscimo, decisão gravada uma vez (trigger em city_triggers.sql).
class CreateCitizenErasureRequests < ActiveRecord::Migration[8.1]
  def up
    add_column :citizens, :erased_at, :timestamptz

    create_table :citizen_erasure_requests, id: :uuid do |t|
      t.string :cpf, null: false
      t.references :presented_citizen, type: :uuid, null: false, foreign_key: { to_table: :citizens }
      t.references :requested_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.boolean :document_checked, null: false
      t.string :status, null: false
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.timestamptz :decided_at
      t.text :reject_reason
      t.timestamps
    end
    add_index :citizen_erasure_requests, :cpf
    add_index :citizen_erasure_requests, :cpf, unique: true, where: "status = 'pending'",
              name: "idx_citizen_erasure_requests_one_pending"
    add_check_constraint :citizen_erasure_requests, "document_checked", name: "ck_citizen_erasure_requests_document"
    add_check_constraint :citizen_erasure_requests, "status IN ('pending','confirmed','rejected','retained')",
                         name: "ck_citizen_erasure_requests_status"
    add_check_constraint :citizen_erasure_requests, "(status = 'pending') = (decided_at IS NULL)",
                         name: "ck_citizen_erasure_requests_decision"
    add_check_constraint :citizen_erasure_requests,
                         "status <> 'rejected' OR length(btrim(coalesce(reject_reason, ''))) >= 10",
                         name: "ck_citizen_erasure_requests_reason"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :citizen_erasure_requests
    remove_column :citizens, :erased_at
  end
end
