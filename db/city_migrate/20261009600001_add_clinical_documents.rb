# db/city_migrate/20261009600001_add_clinical_documents.rb
# Documentos clínicos da consulta (ADR 0033; spec 2026-10-09 §3–§8). Cabeçalho
# comum (clinical_documents, conteúdo JSON cifrado), itens da receita, lista de
# medicamentos em uso por eventos, REMUME, protocolos de enfermagem com versões,
# trilha da página pública e o CNPJ da cidade. O 19b passa a aceitar o
# documento clínico como assinável e o motivo document_cancelled. As tabelas
# do 19a não mudam. Triggers em db/city_triggers.sql.
class AddClinicalDocuments < ActiveRecord::Migration[8.1]
  KINDS = %w[sick_note attendance_declaration prescription exam_requisition].freeze
  ROUTES = %w[oral sublingual topical ophthalmic otic nasal inhalation vaginal rectal intramuscular intravenous
              subcutaneous other].freeze
  SIGNABLE = %w[Consultation ConsultationAddendum ClinicalDocument].freeze
  SIGNATURE_REASONS = %w[no_session session_expired provider_unavailable provider_rejected signer_unavailable
                         verification_failed certificate_expired certificate_revoked certificate_cpf_mismatch
                         feature_disabled user_request document_cancelled].freeze

  def text_in(column, values) = "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"

  def checks(table, map) = map.each { |name, expression| add_check_constraint table, expression, name: name }

  def up
    add_column :city_profile, :cnpj, :string, limit: 14
    add_check_constraint :city_profile, "cnpj IS NULL OR cnpj::text ~ '^[0-9A-Z]{12}[0-9]{2}$'::text", name: "ck_city_profile_cnpj"

    create_table :city_medication_list, id: :uuid do |t|
      t.uuid :catalog_item_id, null: false
      t.uuid :unit_ids, array: true, null: false, default: []
      t.uuid :added_by_user_id, null: false
      t.timestamps
    end
    add_index :city_medication_list, :catalog_item_id, unique: true
    add_index :city_medication_list, :added_by_user_id
    add_foreign_key :city_medication_list, :users, column: :added_by_user_id

    create_table :nursing_protocols, id: :uuid do |t|
      t.string :title, null: false
      t.string :number, null: false, limit: 30
      t.integer :year, null: false
      t.uuid :created_by_user_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :nursing_protocols, %i[number year], unique: true
    add_index :nursing_protocols, :created_by_user_id
    add_foreign_key :nursing_protocols, :users, column: :created_by_user_id
    checks(:nursing_protocols,
           "ck_nursing_protocols_title" => "length(btrim(title::text)) BETWEEN 3 AND 200",
           "ck_nursing_protocols_number" => "length(btrim(number::text)) >= 1",
           "ck_nursing_protocols_year" => "year BETWEEN 1990 AND 2100")

    create_table :nursing_protocol_versions, id: :uuid do |t|
      t.uuid :nursing_protocol_id, null: false
      t.integer :version, null: false
      t.date :valid_from, null: false
      t.date :valid_until
      t.uuid :created_by_user_id, null: false
      t.bigint :txid, null: false, default: -> { "txid_current()" }
      t.datetime :created_at, null: false
    end
    add_index :nursing_protocol_versions, %i[nursing_protocol_id version], unique: true, name: "idx_nursing_protocol_versions_unique"
    add_index :nursing_protocol_versions, :created_by_user_id
    add_foreign_key :nursing_protocol_versions, :nursing_protocols
    add_foreign_key :nursing_protocol_versions, :users, column: :created_by_user_id
    checks(:nursing_protocol_versions,
           "ck_nursing_protocol_versions_validity" => "valid_until IS NULL OR valid_until >= valid_from",
           "ck_nursing_protocol_versions_version" => "version >= 1")

    create_table :nursing_protocol_version_items, id: :uuid do |t|
      t.uuid :nursing_protocol_version_id, null: false
      t.uuid :catalog_item_id, null: false
      t.decimal :max_quantity, precision: 10, scale: 2
      t.string :max_quantity_unit, limit: 30
      t.datetime :created_at, null: false
    end
    add_index :nursing_protocol_version_items, %i[nursing_protocol_version_id catalog_item_id], unique: true,
                                                                                                name: "idx_nursing_protocol_version_items_unique"
    add_foreign_key :nursing_protocol_version_items, :nursing_protocol_versions
    checks(:nursing_protocol_version_items,
           "ck_nursing_protocol_version_items_max" => "(max_quantity IS NULL) = (max_quantity_unit IS NULL) AND (max_quantity IS NULL OR max_quantity > 0)")

    create_table :clinical_documents, id: :uuid do |t|
      t.string :kind, null: false
      t.uuid :patient_id
      t.uuid :citizen_id, null: false
      t.uuid :consultation_id
      t.uuid :attendance_id, null: false
      t.uuid :author_user_id, null: false
      t.string :cbo_code
      t.string :issue_mode, null: false
      t.string :status, null: false, default: "issued"
      t.text :cancel_reason
      t.datetime :cancelled_at
      t.uuid :cancelled_by_user_id
      t.string :verification_token, null: false
      t.string :short_code, null: false, limit: 10
      t.uuid :replaces_document_id
      t.datetime :issued_at, null: false
      t.text :content, null: false
      t.bigint :txid, null: false, default: -> { "txid_current()" }
      t.datetime :created_at, null: false
    end
    add_index :clinical_documents, :verification_token, unique: true
    add_index :clinical_documents, :short_code, unique: true
    add_index :clinical_documents, :replaces_document_id, unique: true, where: "replaces_document_id IS NOT NULL"
    %i[patient_id citizen_id consultation_id attendance_id author_user_id cancelled_by_user_id].each do |column|
      add_index :clinical_documents, column
    end
    add_foreign_key :clinical_documents, :patients
    add_foreign_key :clinical_documents, :citizens
    add_foreign_key :clinical_documents, :consultations
    add_foreign_key :clinical_documents, :attendances
    add_foreign_key :clinical_documents, :users, column: :author_user_id
    add_foreign_key :clinical_documents, :users, column: :cancelled_by_user_id
    add_foreign_key :clinical_documents, :clinical_documents, column: :replaces_document_id
    cancelled = "(status::text = 'cancelled'::text)"
    checks(:clinical_documents,
           "ck_clinical_documents_kind" => text_in("kind", KINDS),
           "ck_clinical_documents_issue_mode" => text_in("issue_mode", %w[digital paper]),
           "ck_clinical_documents_status" => text_in("status", %w[issued cancelled]),
           "ck_clinical_documents_cancellation" => "#{cancelled} = (cancelled_at IS NOT NULL) AND #{cancelled} = (cancel_reason IS NOT NULL) AND #{cancelled} = (cancelled_by_user_id IS NOT NULL)",
           "ck_clinical_documents_short_code" => "short_code::text ~ '^[2-9ABCDEFGHJKMNPQRSTUVWXYZ]{10}$'::text",
           "ck_clinical_documents_token" => "verification_token::text ~ '^[A-Za-z0-9_-]{22}$'::text",
           "ck_clinical_documents_consultation" => "consultation_id IS NOT NULL OR kind::text = 'attendance_declaration'::text",
           "ck_clinical_documents_patient" => "patient_id IS NOT NULL OR kind::text = 'attendance_declaration'::text",
           "ck_clinical_documents_cbo" => "cbo_code IS NULL OR cbo_code::text ~ '^[0-9]{6}$'::text",
           "ck_clinical_documents_cbo_required" => "consultation_id IS NULL OR cbo_code IS NOT NULL",
           "ck_clinical_documents_paper_outside_consultation" => "consultation_id IS NOT NULL OR issue_mode::text = 'paper'::text")

    create_table :prescription_items, id: :uuid do |t|
      t.uuid :clinical_document_id, null: false
      t.integer :position, null: false
      t.uuid :medication_catalog_item_id
      t.integer :catmat_code
      t.uuid :catalog_release_id
      t.text :free_text
      t.text :printed_description, null: false
      t.decimal :quantity, precision: 10, scale: 2, null: false
      t.string :quantity_unit, null: false, limit: 30
      t.string :route, null: false
      t.text :dosage_instructions, null: false
      t.integer :duration_days
      t.boolean :continuous, null: false, default: false
      t.boolean :antimicrobial, null: false, default: false
      t.uuid :nursing_protocol_version_item_id
      t.uuid :reason_problem_id
      t.datetime :created_at, null: false
    end
    add_index :prescription_items, %i[clinical_document_id position], unique: true, name: "idx_prescription_items_position"
    add_index :prescription_items, :medication_catalog_item_id
    add_index :prescription_items, :nursing_protocol_version_item_id
    add_index :prescription_items, :reason_problem_id
    add_foreign_key :prescription_items, :clinical_documents
    add_foreign_key :prescription_items, :nursing_protocol_version_items
    add_foreign_key :prescription_items, :patient_problems, column: :reason_problem_id
    checks(:prescription_items,
           "ck_prescription_items_source" => "(medication_catalog_item_id IS NULL) <> (free_text IS NULL)",
           "ck_prescription_items_catalog" => "(medication_catalog_item_id IS NULL) = (catmat_code IS NULL) AND (medication_catalog_item_id IS NULL) = (catalog_release_id IS NULL)",
           "ck_prescription_items_route" => text_in("route", ROUTES),
           "ck_prescription_items_quantity" => "quantity > 0::numeric AND quantity <= 9999::numeric",
           "ck_prescription_items_duration" => "duration_days IS NULL OR duration_days BETWEEN 1 AND 365",
           "ck_prescription_items_position" => "position >= 1")

    create_table :patient_medications, id: :uuid do |t|
      t.uuid :patient_id, null: false
      t.uuid :catalog_item_id
      t.integer :catmat_code
      t.text :free_text
      t.text :label, null: false
      t.text :dosage_summary
      t.boolean :continuous, null: false, default: true
      t.string :status, null: false
      t.string :origin, null: false
      t.date :started_on
      t.timestamps
    end
    add_index :patient_medications, :patient_id
    add_index :patient_medications, %i[patient_id catalog_item_id], unique: true,
                                                                    where: "status::text = 'active'::text AND catalog_item_id IS NOT NULL",
                                                                    name: "idx_patient_medications_one_active"
    add_foreign_key :patient_medications, :patients
    checks(:patient_medications,
           "ck_patient_medications_status" => text_in("status", %w[active suspended]),
           "ck_patient_medications_origin" => text_in("origin", %w[prescription external]),
           "ck_patient_medications_source" => "(catalog_item_id IS NULL) <> (free_text IS NULL) AND (catalog_item_id IS NULL) = (catmat_code IS NULL)")

    create_table :patient_medication_events, id: :uuid do |t|
      t.uuid :patient_medication_id, null: false
      t.string :kind, null: false
      t.uuid :consultation_id
      t.uuid :addendum_id
      t.uuid :clinical_document_id
      t.uuid :user_id, null: false
      t.string :status_after, null: false
      t.text :dosage_summary
      t.bigint :txid, null: false, default: -> { "txid_current()" }
      t.datetime :created_at, null: false
    end
    %i[patient_medication_id consultation_id addendum_id clinical_document_id user_id].each do |column|
      add_index :patient_medication_events, column
    end
    add_foreign_key :patient_medication_events, :patient_medications, deferrable: :deferred
    add_foreign_key :patient_medication_events, :consultations, deferrable: :deferred
    add_foreign_key :patient_medication_events, :consultation_addenda, column: :addendum_id, deferrable: :deferred
    add_foreign_key :patient_medication_events, :clinical_documents, deferrable: :deferred
    add_foreign_key :patient_medication_events, :users
    checks(:patient_medication_events,
           "ck_patient_medication_events_kind" => text_in("kind", %w[added suspended reactivated changed]),
           "ck_patient_medication_events_status" => text_in("status_after", %w[active suspended]),
           "ck_patient_medication_events_source" => "num_nonnulls(consultation_id, addendum_id, clinical_document_id) = 1")

    create_table :document_verification_lookups, id: :uuid do |t|
      t.uuid :clinical_document_id
      t.string :via, null: false
      t.string :outcome, null: false
      t.datetime :created_at, null: false
    end
    add_index :document_verification_lookups, :clinical_document_id
    add_index :document_verification_lookups, :created_at
    add_foreign_key :document_verification_lookups, :clinical_documents
    checks(:document_verification_lookups,
           "ck_document_verification_lookups_via" => text_in("via", %w[token short_code]),
           "ck_document_verification_lookups_outcome" => text_in("outcome", %w[found not_found]),
           "ck_document_verification_lookups_document" => "(outcome::text = 'found'::text) = (clinical_document_id IS NOT NULL)")

    # 19b (ADR 0032, aberto ao 19c): o documento clínico é assinável; o pedido
    # de documento cancelado sai da fila com document_cancelled.
    remove_check_constraint :signature_requests, name: "ck_signature_requests_document_type"
    add_check_constraint :signature_requests, text_in("document_type", SIGNABLE), name: "ck_signature_requests_document_type"
    remove_check_constraint :signature_requests, name: "ck_signature_requests_reason"
    add_check_constraint :signature_requests, "reason_code IS NULL OR #{text_in('reason_code', SIGNATURE_REASONS)}",
                         name: "ck_signature_requests_reason"
    remove_check_constraint :signatures, name: "ck_signatures_document_type"
    add_check_constraint :signatures, text_in("document_type", SIGNABLE), name: "ck_signatures_document_type"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
