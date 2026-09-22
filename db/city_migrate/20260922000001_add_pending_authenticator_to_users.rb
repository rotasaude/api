# Autenticador pendente (spec 2026-09-22-pending-authenticator-design §3).
#
# Aditiva e nula por padrão: o segredo ATIVO (otp_secret, otp_recovery_codes,
# otp_enabled) não é tocado, e conta já cadastrada segue funcionando sem nada
# a migrar. `last_otp_step` é o mesmo campo que Maintainer usa para recusar a
# repetição de um código dentro da janela de drift.
class AddPendingAuthenticatorToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :otp_pending_secret, :string
    add_column :users, :otp_pending_recovery_codes, :jsonb, null: false, default: []
    add_column :users, :otp_pending_at, :datetime
    add_column :users, :last_otp_step, :integer
  end
end
