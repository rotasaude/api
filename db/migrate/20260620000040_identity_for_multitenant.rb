# Identidade global (ADR-0022):
# - drop users.municipality_id (substituído por memberships, ADR-0023)
# - users.otp_secret (encrypts), otp_enabled, otp_recovery_codes (jsonb), deactivated_at
# - identities (seam gov.br): provider + provider_uid
# Tabelas users/sessions/identities permanecem RLS-exempt.
class IdentityForMultitenant < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :users, :municipalities
    remove_index  :users, :municipality_id
    remove_column :users, :municipality_id

    add_column :users, :otp_secret,          :string
    add_column :users, :otp_enabled,         :boolean, default: false, null: false
    add_column :users, :otp_recovery_codes,  :jsonb,   default: [],    null: false
    add_column :users, :deactivated_at,      :datetime

    create_table :identities, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true, null: false, index: true
      t.string :provider,     null: false    # 'password' | 'govbr' | ...
      t.string :provider_uid, null: false
      t.timestamps
      t.index [:provider, :provider_uid], unique: true
    end
  end

  def down
    drop_table :identities
    remove_column :users, :otp_secret
    remove_column :users, :otp_enabled
    remove_column :users, :otp_recovery_codes
    remove_column :users, :deactivated_at
    add_reference :users, :municipality, type: :uuid, foreign_key: true, index: true
  end
end
