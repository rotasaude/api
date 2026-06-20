class CreateInvitations < ActiveRecord::Migration[8.1]
  def up
    create_table :invitations, id: :uuid do |t|
      t.string     :email,           null: false
      t.references :municipality,    type: :uuid, foreign_key: true, null: true, index: true
      t.string     :role,            null: false
      t.string     :token,           null: false
      t.references :invited_by,      type: :uuid, foreign_key: { to_table: :users }, null: false
      t.datetime   :expires_at,      null: false
      t.datetime   :accepted_at
      t.timestamps
      t.index :token, unique: true
    end

    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON invitations TO rota_app, rota_saude;")
  end

  def down
    drop_table :invitations
  end
end
