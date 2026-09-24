# Validação presencial do cidadão (spec 2026-09-24-citizen-presencial-
# verification-design §3). Aditiva: papel novo no CHECK de memberships e duas
# tabelas. citizen_verifications só aceita acréscimo, exceto preencher a
# revogação uma vez — o trigger vem de db/city_triggers.sql, a mesma fonte que
# load_city_schema executa depois de carregar o dump.
class CreateCitizenVerifications < ActiveRecord::Migration[8.1]
  ROLES_BEFORE = %w[municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze
  ROLES_AFTER = %w[citizen_verifier municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze

  def up
    replace_roles_check(ROLES_AFTER)

    create_table :citizen_verification_codes, id: :uuid do |t|
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.string :code_digest, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    create_table :citizen_verifications, id: :uuid do |t|
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.references :verified_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :verified_at, null: false
      t.datetime :revoked_at
      t.references :revoked_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.text :revoke_reason
      t.datetime :created_at, null: false
    end
    add_index :citizen_verifications, :citizen_id, unique: true, where: "revoked_at IS NULL",
              name: "idx_citizen_verifications_one_active"
    add_check_constraint :citizen_verifications,
                         "(revoked_at IS NULL AND revoked_by_user_id IS NULL AND revoke_reason IS NULL) OR " \
                         "(revoked_at IS NOT NULL AND revoked_by_user_id IS NOT NULL AND revoke_reason IS NOT NULL " \
                         "AND length(btrim(revoke_reason)) >= 10)",
                         name: "ck_citizen_verifications_revocation"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS citizen_verifications_guard ON citizen_verifications"
    execute "DROP TRIGGER IF EXISTS citizen_verifications_append_only_truncate ON citizen_verifications"
    execute "DROP FUNCTION IF EXISTS rota_citizen_verification_guard()"
    drop_table :citizen_verifications
    drop_table :citizen_verification_codes
    replace_roles_check(ROLES_BEFORE)
  end

  private

  # Mesma forma de 20260918000001_create_protocol_signatures.rb: ANY
  # (ARRAY[...]::text[]) é a única que sobrevive ao round-trip migração → dump.
  def replace_roles_check(roles)
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{roles.map { |r| "'#{r}'" }.join(', ')}]::text[])",
                         name: "ck_memberships_role"
  end
end
