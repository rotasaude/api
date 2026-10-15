# Catálogo-base de exames de laboratório da plataforma (ADR 0037; spec §4):
# o maintenance cura, a cidade adota e versiona. Dado público, sem pessoa.
# Sem exclusão (M7): sai de uso por active. E o valor SIGTAP do procedimento
# (VL_SA, centavos) para o relatório de produção.
class CreateLabExamTemplates < ActiveRecord::Migration[8.1]
  SECTORS = %w[biochemistry hematology immunology urinalysis parasitology microbiology].freeze

  def up
    create_table :lab_exam_templates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :sigtap_code, limit: 10, null: false
      t.string :name, limit: 120, null: false
      t.string :sector, null: false
      t.string :material, limit: 60, null: false
      t.string :container, limit: 60, null: false
      t.string :suggested_method, limit: 160
      t.text :preparation
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :sigtap_code, unique: true
      t.check_constraint "sigtap_code::text ~ '^02[0-9]{8}$'::text", name: "ck_lab_exam_templates_sigtap"
      t.check_constraint "sector::text = ANY (ARRAY[#{SECTORS.map { |s| "'#{s}'::text" }.join(', ')}])", name: "ck_lab_exam_templates_sector"
    end

    create_table :lab_analyte_templates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :lab_exam_template, type: :uuid, null: false, foreign_key: true, index: false
      t.string :key, limit: 40, null: false
      t.string :name, limit: 120, null: false
      t.string :loinc, limit: 10
      t.string :unit, limit: 30
      t.string :value_type, null: false
      t.jsonb :choices, null: false, default: []
      t.integer :decimals, null: false, default: 0
      t.jsonb :reference_ranges, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index %i[lab_exam_template_id key], unique: true, name: "idx_lab_analyte_templates_key"
      t.check_constraint "value_type::text = ANY (ARRAY['numeric'::text, 'text'::text, 'choice'::text])", name: "ck_lab_analyte_templates_type"
      t.check_constraint "decimals BETWEEN 0 AND 4", name: "ck_lab_analyte_templates_decimals"
      t.check_constraint "key::text ~ '^[a-z][a-z0-9_]{0,39}$'::text", name: "ck_lab_analyte_templates_key"
    end

    add_column :sigtap_procedures, :amount_sa_cents, :integer
  end

  def down
    remove_column :sigtap_procedures, :amount_sa_cents
    drop_table :lab_analyte_templates
    drop_table :lab_exam_templates
  end
end
