# Canal web do cidadão (spec 2026-09-22-web-citizen-channel §3.3).
#
# Aditiva. CPF e telefone vão cifrados de forma determinística com a chave da
# cidade (a busca por eles precisa do mesmo texto cifrado), como
# conversations.phone. Os checks usam a forma ANY (ARRAY[...]::text[]), a
# única que sobrevive ao round-trip migração → dump → load (ver
# 20260918000001_create_protocol_signatures.rb).
#
# O índice de conversa ativa se divide em dois: por telefone no WhatsApp (o
# que já existia) e por cidadão na web. Assim o mesmo celular tem uma conversa
# ativa em cada canal, e um celular da família tem uma por pessoa na web.
class CreateCitizens < ActiveRecord::Migration[8.1]
  ACTIVE_STATES = "state::text = ANY (ARRAY['greeting', 'awaiting_consent', 'consented']::text[])".freeze

  def up
    create_table :citizens, id: :uuid do |t|
      t.string :cpf, null: false
      t.string :phone, null: false
      t.string :verification_level, null: false, default: "declared"
      t.timestamps
    end
    add_index :citizens, [:cpf, :phone], unique: true
    add_index :citizens, :phone
    add_check_constraint :citizens, "verification_level::text = ANY (ARRAY['declared', 'verified']::text[])",
                         name: "ck_citizens_verification_level"

    create_table :citizen_sessions, id: :uuid do |t|
      t.string :token_digest, null: false
      t.string :phone, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_seen_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :citizen_sessions, :token_digest, unique: true
    add_index :citizen_sessions, :phone

    create_table :otp_challenges, id: :uuid do |t|
      t.string :phone, null: false
      t.string :code_digest, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :otp_challenges, [:phone, :created_at]

    add_column :conversations, :channel, :string, null: false, default: "whatsapp"
    add_reference :conversations, :citizen, type: :uuid, foreign_key: true, index: true
    add_column :conversations, :last_answer_key, :string
    add_check_constraint :conversations, "channel::text = ANY (ARRAY['whatsapp', 'web']::text[])",
                         name: "ck_conversations_channel"

    remove_index :conversations, name: "idx_conversations_active_phone"
    add_index :conversations, :phone, unique: true, name: "idx_conversations_active_phone",
              where: "channel::text = 'whatsapp'::text AND #{ACTIVE_STATES}"
    add_index :conversations, :citizen_id, unique: true, name: "idx_conversations_active_citizen",
              where: "channel::text = 'web'::text AND #{ACTIVE_STATES}"
  end

  def down
    remove_index :conversations, name: "idx_conversations_active_citizen"
    remove_index :conversations, name: "idx_conversations_active_phone"
    add_index :conversations, :phone, unique: true, name: "idx_conversations_active_phone",
              where: ACTIVE_STATES
    remove_check_constraint :conversations, name: "ck_conversations_channel"
    remove_column :conversations, :last_answer_key
    remove_reference :conversations, :citizen, foreign_key: true, index: true
    remove_column :conversations, :channel
    drop_table :otp_challenges
    drop_table :citizen_sessions
    drop_table :citizens
  end
end
