# Catálogo-base das linhas de cuidado (ADR 0040; spec §4): versões
# imutáveis (trigger em db/platform_triggers.sql) das seis linhas C2–C7 com
# as regras das notas metodológicas. Dado público, sem pessoa. Irreversível.
class CreateCareLineTemplates < ActiveRecord::Migration[8.1]
  KEYS = %w[child_c2 pregnancy_c3 diabetes_c4 hypertension_c5 elderly_c6 women_c7].freeze

  def up
    create_table :care_line_templates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :key, null: false
      t.integer :version, null: false
      t.string :name, limit: 120, null: false
      t.string :indicator, limit: 2, null: false
      t.string :declared_condition
      t.jsonb :eligibility, null: false
      t.jsonb :practices, null: false
      t.uuid :created_by_maintainer_id
      t.datetime :created_at, null: false
      t.index %i[key version], unique: true, name: "idx_care_line_templates_version"
      t.check_constraint "key::text = ANY (ARRAY[#{KEYS.map { |k| "'#{k}'::text" }.join(', ')}])", name: "ck_care_line_templates_key"
      t.check_constraint "version >= 1 AND indicator::text ~ '^C[2-7]$'::text AND jsonb_typeof(practices) = 'array'::text " \
                         "AND jsonb_typeof(eligibility) = 'object'::text", name: "ck_care_line_templates_values"
    end
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
