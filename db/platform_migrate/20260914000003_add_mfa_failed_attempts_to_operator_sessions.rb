# Teto de tentativas de TOTP por sessão pendente de operador (Plano 3B).
class AddMfaFailedAttemptsToOperatorSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :operator_sessions, :mfa_failed_attempts, :integer, null: false, default: 0
  end
end
