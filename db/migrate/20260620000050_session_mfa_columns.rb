class SessionMfaColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :mfa_verified_at, :datetime
  end
end
