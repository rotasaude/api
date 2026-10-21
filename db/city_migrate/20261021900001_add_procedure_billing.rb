# Módulo 22 (ADR 0039): procedimento realizado e faturamento BPA. Papel
# billing_clerk; raça/cor, etnia e endereço do paciente (D-U1); procedimentos (só acréscimo no conteúdo clínico: a crítica,
# o cancelamento e o arquivo que o incluiu andam), competências por
# estabelecimento faturante, arquivos (só acréscimo, cifrados) e a
# configuração do cabeçalho. Triggers em db/city_triggers.sql. Irreversível.
class AddProcedureBilling < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager citizen_verifier exam_provider exam_regulator health_professional lab_releaser
             lab_staff municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze
  SOURCES = %w[attendance consultation lab_report manual].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze
  COMPETENCE = "'^[0-9]{4}(0[1-9]|1[0-2])$'::text".freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"

    create_table :billing_settings, id: :uuid do |t|
      t.boolean :singleton, null: false, default: true
      t.string :origin_name, limit: 30, null: false
      t.string :origin_acronym, limit: 6
      t.string :origin_cnpj, limit: 14, null: false
      t.string :destination_body, limit: 40, null: false
      t.string :management, limit: 1, null: false
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :billing_settings, :singleton, unique: true, name: "idx_billing_settings_singleton"
    add_check_constraint :billing_settings, "singleton", name: "ck_billing_settings_singleton"
    add_check_constraint :billing_settings, "origin_cnpj::text ~ '^[0-9]{14}$'::text AND management::text = ANY (ARRAY['M'::text, 'E'::text])",
                         name: "ck_billing_settings_values"

    create_table :billing_periods, id: :uuid do |t|
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.references :exam_provider, type: :uuid, foreign_key: true, index: false
      t.string :competence, limit: 6, null: false
      t.string :status, null: false, default: "open"
      t.integer :version, null: false, default: 0
      t.datetime :closed_at
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :reopened_reason
      t.datetime :reopened_at
      t.references :reopened_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :billing_periods, %i[health_unit_id competence], unique: true, where: "health_unit_id IS NOT NULL", name: "idx_billing_periods_unit"
    add_index :billing_periods, %i[exam_provider_id competence], unique: true, where: "exam_provider_id IS NOT NULL", name: "idx_billing_periods_lab"
    add_index :billing_periods, :competence, name: "idx_billing_periods_competence"
    add_check_constraint :billing_periods, "num_nonnulls(health_unit_id, exam_provider_id) = 1", name: "ck_billing_periods_establishment"
    add_check_constraint :billing_periods, "competence::text ~ #{COMPETENCE}", name: "ck_billing_periods_competence"
    add_check_constraint :billing_periods, "status::text = ANY (ARRAY['open'::text, 'closed'::text]) AND version >= 0", name: "ck_billing_periods_status"
    add_check_constraint :billing_periods, "status::text <> 'closed'::text OR (closed_at IS NOT NULL AND closed_by_user_id IS NOT NULL AND version >= 1)",
                         name: "ck_billing_periods_closed"
    add_check_constraint :billing_periods, "num_nulls(reopened_reason, reopened_at, reopened_by_user_id) IN (0, 3)",
                         name: "ck_billing_periods_reopened"

    create_table :billing_exports, id: :uuid do |t|
      t.references :billing_period, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.string :cnes, limit: 7, null: false
      t.string :competence, limit: 6, null: false
      t.text :file, null: false
      t.string :sha256, limit: 64, null: false
      t.integer :lines_bpa_c, null: false
      t.integer :lines_bpa_i, null: false
      t.integer :sheets, null: false
      t.integer :control_field, null: false
      t.references :generated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :generated_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :billing_exports, %i[billing_period_id version], unique: true, name: "idx_billing_exports_version"
    add_check_constraint :billing_exports, "version >= 1 AND lines_bpa_c >= 0 AND lines_bpa_i >= 0 AND (lines_bpa_c + lines_bpa_i) >= 1 " \
                                           "AND sheets >= 1 AND sheets <= 999 AND control_field >= 1111 AND control_field <= 2221",
                         name: "ck_billing_exports_numbers"
    add_check_constraint :billing_exports, "cnes::text ~ '^[0-9]{7}$'::text AND competence::text ~ #{COMPETENCE} AND sha256::text ~ '^[0-9a-f]{64}$'::text",
                         name: "ck_billing_exports_format"

    create_table :performed_procedures, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.references :exam_provider, type: :uuid, foreign_key: true, index: false
      t.references :professional_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.string :cbo_code, limit: 6
      t.date :performed_on, null: false
      t.string :sigtap_code, limit: 10, null: false
      t.string :sigtap_competence, limit: 6
      t.boolean :sigtap_fallback, null: false, default: false
      t.integer :quantity, null: false
      t.string :cid10, limit: 4
      t.string :character, null: false, default: "elective"
      t.string :authorization_number, limit: 13
      t.string :source, null: false
      t.references :attendance, type: :uuid, foreign_key: true, index: true
      t.references :consultation, type: :uuid, foreign_key: true, index: true
      t.references :lab_report_item, type: :uuid, foreign_key: true,
                                     index: { unique: true, where: "lab_report_item_id IS NOT NULL", name: "idx_performed_procedures_lab_item" }
      t.references :recorded_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.string :instrument, null: false
      t.boolean :billable, null: false
      t.string :blocking_reasons, array: true, null: false, default: []
      t.string :status, null: false, default: "recorded"
      t.text :cancel_reason
      t.datetime :cancelled_at
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :billing_period, type: :uuid, foreign_key: true, index: false
      t.string :billing_competence, limit: 6
      t.boolean :late, null: false, default: false
      t.references :billing_export, type: :uuid, foreign_key: true, index: true
      t.timestamps
    end
    add_index :performed_procedures, %i[patient_id created_at], name: "idx_performed_procedures_patient"
    add_index :performed_procedures, %i[billing_period_id status], name: "idx_performed_procedures_period"
    add_check_constraint :performed_procedures, "num_nonnulls(health_unit_id, exam_provider_id) = 1", name: "ck_performed_procedures_establishment"
    add_check_constraint :performed_procedures, "quantity >= 1 AND quantity <= 999", name: "ck_performed_procedures_quantity"
    add_check_constraint :performed_procedures, "sigtap_code::text ~ '^[0-9]{10}$'::text " \
                                                "AND (cid10 IS NULL OR cid10::text ~ '^[A-Z][0-9]{2}[0-9X]?$'::text) " \
                                                "AND (cbo_code IS NULL OR cbo_code::text ~ '^[0-9]{6}$'::text)",
                         name: "ck_performed_procedures_codes"
    add_check_constraint :performed_procedures, "source::text = ANY (ARRAY[#{quoted(SOURCES)}]::text[]) " \
                                                "AND instrument::text = ANY (ARRAY[#{quoted(INSTRUMENTS)}]::text[]) " \
                                                "AND character::text = ANY (ARRAY[#{quoted(CHARACTERS)}]::text[]) " \
                                                "AND status::text = ANY (ARRAY['recorded'::text, 'cancelled'::text])",
                         name: "ck_performed_procedures_domains"
    add_check_constraint :performed_procedures, "(status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL " \
                                               "AND cancelled_by_user_id IS NOT NULL)",
                         name: "ck_performed_procedures_cancelled"
    add_check_constraint :performed_procedures, "(source::text <> 'attendance'::text OR attendance_id IS NOT NULL) " \
                                                "AND (source::text <> 'consultation'::text OR consultation_id IS NOT NULL) " \
                                                "AND (source::text <> 'lab_report'::text OR (lab_report_item_id IS NOT NULL AND exam_provider_id IS NOT NULL))",
                         name: "ck_performed_procedures_source_ref"
    add_check_constraint :performed_procedures, "NOT billable OR (cardinality(blocking_reasons) = 0 AND instrument::text <> 'not_bpa'::text)",
                         name: "ck_performed_procedures_billable"
    add_check_constraint :performed_procedures, "((billing_period_id IS NULL) = (billing_competence IS NULL)) " \
                                                "AND (billing_competence IS NULL OR billing_competence::text ~ #{COMPETENCE}) " \
                                                "AND (sigtap_competence IS NULL OR sigtap_competence::text ~ #{COMPETENCE}) " \
                                                "AND (billing_export_id IS NULL OR billing_period_id IS NOT NULL)",
                         name: "ck_performed_procedures_competences"

    # D-U1 (contrato §12): raça/cor, etnia e endereço do paciente para o BPA-I,
    # cifrados com a chave da cidade (texto; a validação é do Patients::Demographics).
    %i[race_color ethnicity address_zip address_street address_number address_complement address_district].each do |column|
      add_column :patients, column, :text
    end

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
