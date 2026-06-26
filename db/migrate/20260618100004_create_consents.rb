# Ver ADR-0012.
class CreateConsents < ActiveRecord::Migration[8.0]
  def change
    create_table :consents, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.integer    :version,         null: false
      t.string     :policy_text_sha, null: false
      t.string     :channel,         null: false
      t.text       :evidence                       # encrypts :evidence
      t.datetime   :given_at,        null: false
      t.datetime   :revoked_at
      t.timestamps
    end

    add_index :consents, :given_at
    add_index :consents, [:conversation_id, :revoked_at],
              unique: true,
              where: "revoked_at IS NULL",
              name: "idx_consents_one_active_per_conversation"
  end
end
