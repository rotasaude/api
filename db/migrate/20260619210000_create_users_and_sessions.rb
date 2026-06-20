# Autenticação nativa do Rails 8: User + Session via cookie de sessão
# assinado. Ver ADR-0019.
class CreateUsersAndSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.references :municipality, type: :uuid, foreign_key: true, index: true
      t.timestamps
    end

    add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email"

    create_table :sessions, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true, null: false, index: true
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end
  end
end
