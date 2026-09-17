# Identidade da API de manutenção, no banco de PLATAFORMA (spec §6). Espelha
# operators/operator_sessions: mesma cifra de otp_secret, mesmo índice único por
# lower(email). password_digest é NULO até o convite ser aceito — o mantenedor
# nasce do convite, não de um formulário de senha.
class CreateMaintainers < ActiveRecord::Migration[8.1]
  def change
    create_table :maintainers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string   :email_address, null: false
      t.string   :password_digest
      t.string   :otp_secret
      t.jsonb    :otp_recovery_codes, null: false, default: []
      t.datetime :otp_enabled_at
      t.datetime :deactivated_at
      t.integer  :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.uuid     :invited_by_id
      t.timestamps
      t.index "lower(email_address)", unique: true, name: "index_maintainers_on_lower_email"
    end

    create_table :maintainer_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid     :maintainer_id, null: false
      t.datetime :mfa_verified_at
      t.datetime :last_seen_at
      t.integer  :totp_attempts, null: false, default: 0
      t.string   :ip_address
      t.string   :user_agent
      t.timestamps
      t.index :maintainer_id
    end

    create_table :maintainer_invitations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid     :maintainer_id, null: false
      t.string   :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
      t.index :token_digest, unique: true
      t.index :maintainer_id
    end
  end
end
