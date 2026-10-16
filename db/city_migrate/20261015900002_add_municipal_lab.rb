# Módulo 21b (ADR 0037): laboratório municipal sobre o rastreamento do 21a.
# Papéis lab_staff e lab_releaser; flags de prestador e unidade; origem
# lab_reception, fonte lab e evento result_rectified no 21a; retificação do
# resultado por acréscimo (replaces_result_id); assinatura do laudo pelo 19b
# (LabReport, sem consulta); conferência pública do laudo; as tabelas lab_*.
# Triggers e a sequência do número em db/city_triggers.sql. Irreversível.
class AddMunicipalLab < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst campaign_manager citizen_verifier exam_provider exam_regulator health_professional lab_releaser lab_staff
             municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze
  ORIGINS = %w[consultation reception_guide pec lab_reception].freeze
  EVENT_KINDS = %w[requested authorized denied scheduled collected resulted acknowledged escalated cancelled result_rectified].freeze
  SOURCES = %w[unit provider fhir consultation lab].freeze
  SIGNABLE = %w[Consultation ConsultationAddendum ClinicalDocument LabReport].freeze
  SECTORS = %w[biochemistry hematology immunology urinalysis parasitology microbiology].freeze
  FLAGS = %w[normal low high critical_low critical_high].freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"

    add_column :exam_providers, :uses_municipal_lab, :boolean, null: false, default: false
    add_column :exam_providers, :address, :string, limit: 200
    add_column :exam_providers, :phone, :string, limit: 11
    add_check_constraint :exam_providers, "phone IS NULL OR phone::text ~ '^[0-9]{10,11}$'::text", name: "ck_exam_providers_phone"
    add_column :health_units, :collects_samples, :boolean, null: false, default: false
    add_column :exam_orders, :gal_requisition, :string, limit: 30
    add_check_constraint :exam_orders, "gal_requisition IS NULL OR gal_requisition::text ~ '^[0-9A-Za-z-]{1,30}$'::text", name: "ck_exam_orders_gal"
    replace_check :exam_orders, "ck_exam_orders_origin", "origin::text = ANY (ARRAY[#{quoted(ORIGINS)}]::text[])"
    replace_check :exam_order_events, "ck_exam_order_events_kind", "kind::text = ANY (ARRAY[#{quoted(EVENT_KINDS)}]::text[])"
    replace_check :exam_results, "ck_exam_results_source", "source::text = ANY (ARRAY[#{quoted(SOURCES)}]::text[])"

    add_reference :exam_results, :replaces_result, type: :uuid, foreign_key: { to_table: :exam_results }, index: { unique: true }
    remove_index :exam_results, name: "index_exam_results_on_exam_order_id"
    add_index :exam_results, :exam_order_id, name: "idx_exam_results_order"
    add_index :exam_results, :exam_order_id, unique: true, where: "replaces_result_id IS NULL", name: "idx_exam_results_order_original"
    add_check_constraint :exam_results, "replaces_result_id IS NULL OR origin::text = 'order'::text", name: "ck_exam_results_replaces"

    change_column_null :signature_requests, :consultation_id, true
    replace_check :signature_requests, "ck_signature_requests_document_type", "document_type::text = ANY (ARRAY[#{quoted(SIGNABLE)}]::text[])"
    add_check_constraint :signature_requests, "(document_type::text = 'LabReport'::text) = (consultation_id IS NULL)", name: "ck_signature_requests_consultation"
    replace_check :signatures, "ck_signatures_document_type", "document_type::text = ANY (ARRAY[#{quoted(SIGNABLE)}]::text[])"

    create_table :lab_exams, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :lab_exam_template_id
      t.string :sigtap_code, limit: 10, null: false
      t.string :name, limit: 120, null: false
      t.string :sector, null: false
      t.string :bench, limit: 60
      t.integer :delivery_days, null: false
      t.boolean :active, null: false, default: true
      t.uuid :current_version_id
      t.timestamps
    end
    add_index :lab_exams, %i[exam_provider_id sigtap_code], unique: true, name: "idx_lab_exams_provider_sigtap"
    add_check_constraint :lab_exams, "sigtap_code::text ~ '^02[0-9]{8}$'::text", name: "ck_lab_exams_sigtap"
    add_check_constraint :lab_exams, "sector::text = ANY (ARRAY[#{quoted(SECTORS)}]::text[])", name: "ck_lab_exams_sector"
    add_check_constraint :lab_exams, "delivery_days BETWEEN 1 AND 90", name: "ck_lab_exams_delivery_days"

    create_table :lab_exam_versions, id: :uuid do |t|
      t.references :lab_exam, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      # Coluna analysis_method (não "method": sobrescreveria Object#method); a
      # chave "method" do JSON da API mapeia para ela.
      t.string :analysis_method, limit: 160, null: false
      t.string :material, limit: 60, null: false
      t.string :container, limit: 60, null: false
      t.string :instrument_test_code, limit: 30
      t.jsonb :analytes, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :lab_exam_versions, %i[lab_exam_id version], unique: true, name: "idx_lab_exam_versions_number"
    add_check_constraint :lab_exam_versions, "version >= 1", name: "ck_lab_exam_versions_version"
    add_check_constraint :lab_exam_versions, "jsonb_typeof(analytes) = 'array' AND jsonb_array_length(analytes) BETWEEN 1 AND 60", name: "ck_lab_exam_versions_analytes"
    add_check_constraint :lab_exam_versions, "instrument_test_code IS NULL OR instrument_test_code::text ~ '^[A-Za-z0-9._-]{1,30}$'::text", name: "ck_lab_exam_versions_instrument"
    add_foreign_key :lab_exams, :lab_exam_versions, column: :current_version_id

    create_table :lab_rejection_reasons, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 80, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :lab_rejection_reasons, "exam_provider_id, lower((name)::text)", unique: true, name: "idx_lab_rejection_reasons_name"

    create_table :lab_releasers, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.boolean :technical_lead, null: false, default: false
      t.boolean :technical_deputy, null: false, default: false
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :ended_at
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :lab_releasers, %i[user_id exam_provider_id], unique: true, where: "ended_at IS NULL", name: "idx_lab_releasers_active"
    add_index :lab_releasers, :exam_provider_id, unique: true, where: "ended_at IS NULL AND technical_lead", name: "idx_lab_releasers_lead"
    add_index :lab_releasers, :exam_provider_id, unique: true, where: "ended_at IS NULL AND technical_deputy", name: "idx_lab_releasers_deputy"
    add_check_constraint :lab_releasers, "NOT (technical_lead AND technical_deputy)", name: "ck_lab_releasers_marks"

    create_table :lab_middleware_tokens, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :token_digest, limit: 64, null: false
      t.boolean :simulated, null: false, default: false
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :revoked_at
      t.datetime :created_at, null: false
    end
    add_index :lab_middleware_tokens, :token_digest, unique: true
    add_index :lab_middleware_tokens, :exam_provider_id, unique: true, where: "revoked_at IS NULL", name: "idx_lab_middleware_tokens_active"

    create_table :lab_requisitions, id: :uuid do |t|
      t.string :number, limit: 8, null: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.references :origin_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: false
      t.string :collection_place, null: false
      t.string :biological_sex, null: false
      t.text :mother_name, null: false
      t.boolean :urgent, null: false, default: false
      t.text :clinical_info
      t.date :expected_delivery_on, null: false
      t.string :status, null: false, default: "open"
      t.text :delivered_to
      t.datetime :delivered_at
      t.references :delivered_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :opened_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :lab_requisitions, :number, unique: true
    add_index :lab_requisitions, %i[exam_provider_id status created_at], name: "idx_lab_requisitions_provider_status"
    add_index :lab_requisitions, %i[origin_unit_id created_at], name: "idx_lab_requisitions_origin"
    add_index :lab_requisitions, %i[patient_id created_at], name: "idx_lab_requisitions_patient"
    add_check_constraint :lab_requisitions, "number::text ~ '^[0-9]{8}$'::text", name: "ck_lab_requisitions_number"
    add_check_constraint :lab_requisitions, "collection_place::text = ANY (ARRAY['ubs'::text, 'lab'::text])", name: "ck_lab_requisitions_place"
    add_check_constraint :lab_requisitions, "biological_sex::text = ANY (ARRAY['male'::text, 'female'::text])", name: "ck_lab_requisitions_sex"
    add_check_constraint :lab_requisitions, "status::text = ANY (ARRAY['open'::text, 'in_analysis'::text, 'typed'::text, 'released'::text, 'delivered'::text])", name: "ck_lab_requisitions_status"
    add_check_constraint :lab_requisitions, "(status::text = 'delivered'::text) = (delivered_at IS NOT NULL AND delivered_to IS NOT NULL)", name: "ck_lab_requisitions_delivery"

    create_table :lab_shipments, id: :uuid do |t|
      t.references :origin_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: false
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.decimal :temperature_celsius, precision: 4, scale: 1, null: false
      t.string :status, null: false, default: "open"
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :sent_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :sent_at
      t.references :received_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :received_at
      t.timestamps
    end
    add_index :lab_shipments, %i[exam_provider_id status], name: "idx_lab_shipments_provider_status"
    add_index :lab_shipments, %i[origin_unit_id status], name: "idx_lab_shipments_origin_status"
    add_check_constraint :lab_shipments, "status::text = ANY (ARRAY['open'::text, 'sent'::text, 'received'::text])", name: "ck_lab_shipments_status"
    add_check_constraint :lab_shipments, "temperature_celsius BETWEEN -30 AND 60", name: "ck_lab_shipments_temperature"

    create_table :lab_samples, id: :uuid do |t|
      t.references :lab_requisition, type: :uuid, null: false, foreign_key: true, index: true
      t.string :barcode, limit: 10, null: false
      t.string :material, limit: 60, null: false
      t.string :container, limit: 60, null: false
      t.string :status, null: false, default: "awaiting"
      t.references :collected_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :collected_at
      t.references :lab_shipment, type: :uuid, foreign_key: true, index: true
      t.references :received_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :received_at
      t.references :lab_rejection_reason, type: :uuid, foreign_key: true, index: false
      t.string :restriction_note, limit: 300
      t.references :recollection_of, type: :uuid, foreign_key: { to_table: :lab_samples }, index: { unique: true }
      t.timestamps
    end
    add_index :lab_samples, :barcode, unique: true
    add_index :lab_samples, %i[status received_at], name: "idx_lab_samples_status_received"
    add_check_constraint :lab_samples, "barcode::text ~ '^[0-9]{10}$'::text", name: "ck_lab_samples_barcode"
    add_check_constraint :lab_samples, "status::text = ANY (ARRAY['awaiting'::text, 'in_transit'::text, 'received'::text, 'rejected'::text, 'accepted_with_restriction'::text, 'not_received'::text])", name: "ck_lab_samples_status"
    add_check_constraint :lab_samples, "(status::text = 'rejected'::text) = (lab_rejection_reason_id IS NOT NULL)", name: "ck_lab_samples_rejection"
    add_check_constraint :lab_samples, "(status::text = 'accepted_with_restriction'::text) = (restriction_note IS NOT NULL)", name: "ck_lab_samples_restriction"
    add_check_constraint :lab_samples, "status::text = 'awaiting'::text OR collected_at IS NOT NULL", name: "ck_lab_samples_collected"
    add_check_constraint :lab_samples, "status::text NOT IN ('received', 'rejected', 'accepted_with_restriction') OR received_at IS NOT NULL", name: "ck_lab_samples_received"

    create_table :lab_requisition_items, id: :uuid do |t|
      t.references :lab_requisition, type: :uuid, null: false, foreign_key: true, index: true
      t.references :exam_order, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :lab_exam_version, type: :uuid, null: false, foreign_key: true, index: false
      t.references :lab_sample, type: :uuid, null: false, foreign_key: true, index: true
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_check_constraint :lab_requisition_items, "status::text = ANY (ARRAY['pending'::text, 'typed'::text, 'released'::text, 'cancelled'::text])", name: "ck_lab_requisition_items_status"

    create_table :lab_hl7_receipts, id: :uuid do |t|
      t.references :lab_middleware_token, type: :uuid, null: false, foreign_key: true, index: false
      t.string :control_id, limit: 64, null: false
      t.string :message_type, limit: 20, null: false
      # Nulo = bruto purgado (retenção a decidir); o trigger só aceita re-cifra ou purga.
      t.text :raw
      t.datetime :created_at, null: false
    end
    add_index :lab_hl7_receipts, %i[lab_middleware_token_id control_id], unique: true, name: "idx_lab_hl7_receipts_control"

    create_table :lab_results, id: :uuid do |t|
      t.references :lab_requisition_item, type: :uuid, null: false, foreign_key: true, index: false
      t.string :analyte_key, limit: 40, null: false
      t.text :value, null: false
      t.string :unit, limit: 30
      t.string :flag, null: false
      t.string :source, null: false
      t.references :lab_hl7_receipt, type: :uuid, foreign_key: true, index: true
      t.references :entered_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :entered_at, null: false
      t.boolean :chosen, null: false, default: false
      t.references :chosen_from, type: :uuid, foreign_key: { to_table: :lab_results }, index: false
      t.datetime :created_at, null: false
    end
    add_index :lab_results, %i[lab_requisition_item_id analyte_key created_at], name: "idx_lab_results_item_analyte"
    add_check_constraint :lab_results, "flag::text = ANY (ARRAY[#{quoted(FLAGS)}]::text[])", name: "ck_lab_results_flag"
    add_check_constraint :lab_results, "source::text = ANY (ARRAY['typed'::text, 'hl7'::text])", name: "ck_lab_results_source"
    add_check_constraint :lab_results, "entered_by_user_id IS NOT NULL OR lab_hl7_receipt_id IS NOT NULL", name: "ck_lab_results_actor"
    add_check_constraint :lab_results, "chosen = (chosen_from_id IS NOT NULL)", name: "ck_lab_results_choice"
    add_check_constraint :lab_results, "source::text = 'typed'::text OR lab_hl7_receipt_id IS NOT NULL", name: "ck_lab_results_hl7"

    create_table :lab_reports, id: :uuid do |t|
      # Sem índice próprio: idx_lab_reports_version (lab_requisition_id, version) o cobre.
      t.references :lab_requisition, type: :uuid, null: false, foreign_key: true, index: false
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.references :replaces_report, type: :uuid, foreign_key: { to_table: :lab_reports }, index: false
      t.boolean :partial, null: false, default: false
      t.string :status, null: false
      t.string :signature_kind, null: false
      t.references :released_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :released_at
      t.text :content, null: false
      t.string :content_sha256, limit: 64, null: false
      t.references :pdf_file, type: :uuid, foreign_key: { to_table: :exam_files }, index: { unique: true }
      t.string :pdf_sha256, limit: 64
      t.string :verification_token, limit: 22, null: false
      t.string :short_code, limit: 10, null: false
      t.text :rectification_reason
      t.text :rectification_contacts
      t.timestamps
    end
    add_index :lab_reports, %i[lab_requisition_id version], unique: true, name: "idx_lab_reports_version"
    add_index :lab_reports, :verification_token, unique: true
    add_index :lab_reports, :short_code, unique: true
    add_index :lab_reports, %i[exam_provider_id released_at], name: "idx_lab_reports_provider_released"
    # Uma retificação viva por laudo; a retirada (ICP devolvido) não bloqueia a próxima.
    add_index :lab_reports, :replaces_report_id, unique: true, where: "status::text <> 'withdrawn'::text", name: "idx_lab_reports_replaces"
    add_check_constraint :lab_reports, "verification_token::text ~ '^[A-Za-z0-9_-]{22}$'::text", name: "ck_lab_reports_token"
    add_check_constraint :lab_reports, "status::text = ANY (ARRAY['pending_signature'::text, 'released'::text, 'rectified'::text, 'withdrawn'::text])", name: "ck_lab_reports_status"
    add_check_constraint :lab_reports, "signature_kind::text = ANY (ARRAY['icp'::text, 'advanced'::text])", name: "ck_lab_reports_signature"
    add_check_constraint :lab_reports, "status::text IN ('pending_signature', 'withdrawn') OR (released_at IS NOT NULL AND pdf_file_id IS NOT NULL AND pdf_sha256 IS NOT NULL)", name: "ck_lab_reports_released"
    add_check_constraint :lab_reports, "(replaces_report_id IS NULL) = (rectification_reason IS NULL)", name: "ck_lab_reports_rectification"
    add_check_constraint :lab_reports, "short_code::text ~ '^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{10}$'::text", name: "ck_lab_reports_short_code"

    create_table :lab_report_items, id: :uuid do |t|
      t.references :lab_report, type: :uuid, null: false, foreign_key: true, index: false
      t.references :lab_requisition_item, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :created_at, null: false
    end
    add_index :lab_report_items, %i[lab_report_id lab_requisition_item_id], unique: true, name: "idx_lab_report_items_pair"

    # Fila de críticos sem aviso (B52): só as linhas críticas, poucas.
    add_index :lab_results, :lab_requisition_item_id, where: "flag::text = ANY (ARRAY['critical_low'::text, 'critical_high'::text])", name: "idx_lab_results_critical"

    create_table :lab_critical_notices, id: :uuid do |t|
      t.references :lab_result, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.text :notified_person, null: false
      t.string :notified_role, limit: 60, null: false
      t.string :channel, null: false
      t.datetime :notified_at, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :lab_critical_notices, "channel::text = ANY (ARRAY['telefone'::text, 'presencial'::text, 'sistema'::text])", name: "ck_lab_critical_notices_channel"

    add_reference :document_verification_lookups, :lab_report, type: :uuid, foreign_key: true, index: true
    replace_check :document_verification_lookups, "ck_document_verification_lookups_document",
                  "(outcome::text = 'found'::text) = (clinical_document_id IS NOT NULL OR lab_report_id IS NOT NULL) AND (clinical_document_id IS NULL OR lab_report_id IS NULL)"

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
