# Assinaturas de protocolo (spec 2026-09-18-protocol-signatures-design §3, §5).
#
# Aditiva: um papel novo no CHECK de memberships e três tabelas que só aceitam
# acréscimo. Os triggers vêm de db/city_triggers.sql, a mesma fonte que
# load_city_schema executa depois de carregar o dump.
class CreateProtocolSignatures < ActiveRecord::Migration[8.1]
  ROLES_BEFORE = %w[municipal_admin protocol_author protocol_publisher viewer].freeze
  ROLES_AFTER = %w[municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze

  def up
    replace_roles_check(ROLES_AFTER)

    create_table :protocol_contributions, id: :uuid do |t|
      t.references :protocol_definition, type: :uuid, null: false, foreign_key: true, index: true
      t.uuid :actor_id, null: false
      t.string :actor_kind, null: false
      t.string :content_digest, null: false
      t.datetime :created_at, null: false
    end
    # Forma ANY (ARRAY[...]::text[]) com literais sem cast, não "IN (...)": é a
    # única que sobrevive ao round-trip migração → dump → load_schema sem
    # mudar de forma. "IN (...)" faz o Postgres reescrever para
    # ANY ((ARRAY[...])::text[]) com cada literal casteado a character
    # varying; ao reexecutar esse texto (carregado do dump) o parser funde a
    # constante de outro jeito (ARRAY[(...)::text, ...]) — duas formas
    # diferentes, e o spec de paridade (city_schema_spec.rb) pega a
    # divergência. ck_memberships_role (abaixo) já usava esta forma estável;
    # os checks novos seguem o mesmo padrão.
    add_check_constraint :protocol_contributions, "actor_kind::text = ANY (ARRAY['user', 'maintainer']::text[])",
                         name: "ck_protocol_contributions_actor_kind"

    create_table :protocol_signatures, id: :uuid do |t|
      t.references :protocol_definition, type: :uuid, null: false, foreign_key: true, index: true
      t.string :purpose, null: false
      t.references :signer_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.string :content_digest, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :protocol_signatures, "purpose::text = ANY (ARRAY['publication', 'activation']::text[])",
                         name: "ck_protocol_signatures_purpose"

    create_table :protocol_activations, id: :uuid do |t|
      t.references :protocol_definition, type: :uuid, null: false, foreign_key: true, index: true
      t.string :kind, null: false
      t.uuid :actor_id, null: false
      t.string :actor_kind, null: false
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_check_constraint :protocol_activations, "kind::text = ANY (ARRAY['signed', 'emergency_revert']::text[])",
                         name: "ck_protocol_activations_kind"
    add_check_constraint :protocol_activations, "actor_kind::text = ANY (ARRAY['user', 'maintainer']::text[])",
                         name: "ck_protocol_activations_actor_kind"
    # kind = 'signed' OR length(btrim(reason)) > 0 evaluates to NULL (not
    # false) quando kind = 'emergency_revert' e reason IS NULL — Postgres
    # trata NULL como aprovação de CHECK, não como recusa (achado do review:
    # uma reversão de emergência sem motivo passava sempre que o modelo fosse
    # contornado). O IS NOT NULL explícito fecha isso.
    add_check_constraint :protocol_activations,
                         "kind = 'signed' OR (reason IS NOT NULL AND length(btrim(reason)) > 0)",
                         name: "ck_protocol_activations_revert_reason"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP FUNCTION IF EXISTS rota_append_only() CASCADE"
    drop_table :protocol_activations
    drop_table :protocol_signatures
    drop_table :protocol_contributions
    replace_roles_check(ROLES_BEFORE)
  end

  private

  def replace_roles_check(roles)
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{roles.map { |r| "'#{r}'" }.join(', ')}]::text[])",
                         name: "ck_memberships_role"
  end
end
