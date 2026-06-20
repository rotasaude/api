# Autoria de protocolos. Stub mínimo. Auth real fica em ADR futuro.
class CreateAuthors < ActiveRecord::Migration[8.0]
  def change
    create_table :authors, id: :uuid do |t|
      t.references :municipality, type: :uuid, foreign_key: true
      t.string :email, null: false
      t.string :token, null: false       # encrypts :token, deterministic: true
      t.string :name
      t.timestamps
    end

    add_index :authors, :email, unique: true
    add_index :authors, :token, unique: true
  end
end
