# db/platform_migrate/20261005200002_create_terminologies.rb
# Terminologias nacionais na plataforma (ADR 0028; spec 2026-10-05 §4):
# CID-10, CIAP-2 e SIGTAP versionadas (a SIGTAP por competência AAAAMM),
# importadas pelo operador, ativadas só no fim e nunca apagadas. Dado público,
# sem dado de pessoa. Os códigos referenciam o procedimento pelo CÓDIGO (não
# por id), como o arquivo oficial, para a carga em lote. Imutabilidade por
# trigger: db/platform_triggers.sql.
class CreateTerminologies < ActiveRecord::Migration[8.1]
  def self.text_in(column, values)
    "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"
  end

  def up
    create_table :terminology_releases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :kind, null: false
      t.string :version, null: false, limit: 20
      t.string :source_sha256, null: false, limit: 64
      t.string :imported_by, null: false, limit: 80
      t.datetime :imported_at, null: false
      t.string :status, null: false, default: "importing"
      t.datetime :activated_at
      t.timestamps
      t.index %i[kind version], unique: true, where: "((status)::text = 'active'::text)",
                                name: "idx_terminology_releases_one_active"
      t.index %i[kind status version], name: "idx_terminology_releases_lookup"
      t.check_constraint self.class.text_in("kind", %w[cid10 ciap2 sigtap]), name: "ck_terminology_releases_kind"
      t.check_constraint self.class.text_in("status", %w[importing active superseded failed]), name: "ck_terminology_releases_status"
      t.check_constraint "kind::text <> 'sigtap'::text OR version::text ~ '^[0-9]{6}$'::text",
                         name: "ck_terminology_releases_sigtap_version"
    end

    create_table :cid10_codes do |t|
      t.uuid :release_id, null: false
      t.string :code, null: false, limit: 4
      t.text :description, null: false
      t.string :sex_restriction, limit: 1
      t.index %i[release_id code], unique: true
      t.check_constraint "sex_restriction IS NULL OR #{self.class.text_in('sex_restriction', %w[F M])}", name: "ck_cid10_codes_sex"
    end

    create_table :ciap2_codes do |t|
      t.uuid :release_id, null: false
      t.string :code, null: false, limit: 3
      t.text :description, null: false
      t.index %i[release_id code], unique: true
    end

    create_table :sigtap_procedures do |t|
      t.uuid :release_id, null: false
      t.string :code, null: false, limit: 10
      t.text :name, null: false
      t.string :sex, limit: 1
      t.integer :age_min_months
      t.integer :age_max_months
      t.string :complexity, limit: 1
      t.index %i[release_id code], unique: true
    end

    create_table :sigtap_procedure_cbos do |t|
      t.uuid :release_id, null: false
      t.string :procedure_code, null: false, limit: 10
      t.string :cbo_code, null: false, limit: 6
      t.index %i[release_id procedure_code cbo_code], unique: true, name: "idx_sigtap_procedure_cbos_unique"
    end

    create_table :sigtap_procedure_cids do |t|
      t.uuid :release_id, null: false
      t.string :procedure_code, null: false, limit: 10
      t.string :cid_code, null: false, limit: 4
      t.boolean :principal, null: false, default: false
      t.index %i[release_id procedure_code cid_code], unique: true, name: "idx_sigtap_procedure_cids_unique"
    end

    create_table :sigtap_procedure_instruments do |t|
      t.uuid :release_id, null: false
      t.string :procedure_code, null: false, limit: 10
      t.string :instrument_code, null: false, limit: 2
      t.string :instrument_name, null: false
      t.index %i[release_id procedure_code instrument_code], unique: true, name: "idx_sigtap_procedure_instruments_unique"
    end

    %i[cid10_codes ciap2_codes sigtap_procedures sigtap_procedure_cbos sigtap_procedure_cids
       sigtap_procedure_instruments].each do |table|
      add_foreign_key table, :terminology_releases, column: :release_id
    end

    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS terminology_releases_guard ON terminology_releases;
      DROP FUNCTION IF EXISTS terminology_release_guard() CASCADE;
      DROP FUNCTION IF EXISTS terminology_codes_guard() CASCADE;
    SQL
    %i[sigtap_procedure_instruments sigtap_procedure_cids sigtap_procedure_cbos sigtap_procedures ciap2_codes
       cid10_codes terminology_releases].each { |table| drop_table table }
  end
end
