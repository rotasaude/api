# apps/api/db/migrate/20260620000070_create_memberships.rb
# Memberships (ADR-0023). RLS-exempt: control plane.
# (user_id, municipality_id, role) único parcial WHERE revoked_at IS NULL.
# municipality_id NULL + role 'platform_operator' = tier de plataforma.
class CreateMemberships < ActiveRecord::Migration[8.1]
  ROLES = %w[platform_operator municipal_admin protocol_author protocol_publisher viewer].freeze

  def up
    create_table :memberships, id: :uuid do |t|
      t.references :user,         type: :uuid, foreign_key: true, null: false, index: true
      t.references :municipality, type: :uuid, foreign_key: true, null: true,  index: true
      t.string     :role,         null: false
      t.references :granted_by,   type: :uuid, foreign_key: { to_table: :users }, null: true
      t.datetime   :granted_at,   null: false
      t.datetime   :revoked_at
      t.timestamps
    end

    add_check_constraint :memberships,
      "role IN (#{ROLES.map { |r| "'#{r}'" }.join(',')})",
      name: "ck_memberships_role"

    # Único parcial: uma role ativa por (user, municipality)
    execute(<<~SQL.squish)
      CREATE UNIQUE INDEX idx_memberships_unique_active
        ON memberships (user_id, COALESCE(municipality_id, '00000000-0000-0000-0000-000000000000'::uuid), role)
        WHERE revoked_at IS NULL;
    SQL

    # platform_operator só com municipality_id NULL
    add_check_constraint :memberships,
      "(role <> 'platform_operator') OR (municipality_id IS NULL)",
      name: "ck_memberships_operator_global"

    # Control plane: sem RLS, mas app roles precisam de acesso DML.
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON memberships TO rota_app, rota_saude;")
  end

  def down
    drop_table :memberships
  end
end
