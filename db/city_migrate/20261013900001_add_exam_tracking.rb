# Módulo 21a (ADR 0036): rastreamento do exame. Catálogo e prestadores da
# cidade, o pedido com cache da situação, a trilha só de acréscimo, o
# resultado imutável e os arquivos cifrados (guia e laudo). Prioridade no
# pedido do 19a. Papéis exam_regulator e exam_provider. Convite ligado a um
# prestador. Triggers em db/city_triggers.sql. Tabelas novas: índices sem
# CONCURRENTLY. Irreversível.
class AddExamTracking < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst campaign_manager citizen_verifier exam_provider exam_regulator health_professional municipal_admin
             protocol_author protocol_publisher protocol_reviewer viewer].freeze
  STAGES = %w[authorize schedule collect result acknowledge].freeze

  def up
    add_column :consultation_exam_requests, :priority, :string, null: false, default: "routine"
    add_check_constraint :consultation_exam_requests, "priority::text = ANY (ARRAY['routine'::text, 'urgent'::text])",
                         name: "ck_consultation_exam_requests_priority"
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])", name: "ck_memberships_role"

    create_table :exam_providers, id: :uuid do |t|
      t.string :name, limit: 120, null: false
      t.string :cnes, limit: 7
      t.string :kind, null: false
      t.boolean :active, null: false, default: true
      t.boolean :simulated, null: false, default: false
      t.string :fhir_token_digest, limit: 64
      t.datetime :fhir_token_rotated_at
      t.datetime :fhir_token_revoked_at
      t.timestamps
    end
    add_index :exam_providers, "lower((name)::text)", unique: true, name: "idx_exam_providers_name_ci"
    add_index :exam_providers, :fhir_token_digest, unique: true, where: "fhir_token_digest IS NOT NULL",
                                                   name: "idx_exam_providers_token"
    add_check_constraint :exam_providers, "kind::text = ANY (ARRAY['municipal'::text, 'accredited'::text, 'consortium'::text, 'lacen'::text, 'imaging'::text])",
                         name: "ck_exam_providers_kind"
    add_check_constraint :exam_providers, "cnes IS NULL OR cnes::text ~ '^[0-9]{7}$'::text", name: "ck_exam_providers_cnes"

    create_table :exam_catalog_items, id: :uuid do |t|
      t.string :sigtap_code, limit: 10, null: false
      t.boolean :requires_authorization, null: false, default: false
      t.string :release_policy, null: false, default: "after_acknowledgement"
      STAGES.each { |stage| t.integer :"#{stage}_days" }
      t.jsonb :result_fields, null: false, default: []
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :exam_catalog_items, :sigtap_code, unique: true
    add_check_constraint :exam_catalog_items, "sigtap_code::text ~ '^02[0-9]{8}$'::text", name: "ck_exam_catalog_items_sigtap"
    add_check_constraint :exam_catalog_items, "release_policy::text = ANY (ARRAY['immediate'::text, 'after_acknowledgement'::text, 'never_citizen'::text])",
                         name: "ck_exam_catalog_items_policy"
    add_check_constraint :exam_catalog_items, days_check, name: "ck_exam_catalog_items_days"

    create_table :exam_provider_items, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.references :exam_catalog_item, type: :uuid, null: false, foreign_key: true
      STAGES.each { |stage| t.integer :"#{stage}_days" }
      t.timestamps
    end
    add_index :exam_provider_items, %i[exam_provider_id exam_catalog_item_id], unique: true, name: "idx_exam_provider_items_pair"
    add_check_constraint :exam_provider_items, days_check, name: "ck_exam_provider_items_days"

    create_table :exam_provider_users, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.datetime :created_at, null: false
    end

    add_reference :invitations, :exam_provider, type: :uuid, foreign_key: true

    create_table :exam_files, id: :uuid do |t|
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :sha256, limit: 64, null: false
      t.text :data, null: false
      t.references :uploaded_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.references :exam_provider, type: :uuid, foreign_key: true
      t.datetime :consumed_at
      t.datetime :created_at, null: false
    end
    add_index :exam_files, :created_at, where: "consumed_at IS NULL", name: "idx_exam_files_orphans"
    add_check_constraint :exam_files, "content_type::text = ANY (ARRAY['application/pdf'::text, 'image/jpeg'::text, 'image/png'::text])",
                         name: "ck_exam_files_content_type"
    add_check_constraint :exam_files, "byte_size > 0 AND byte_size <= 10485760", name: "ck_exam_files_size"

    create_table :exam_orders, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.string :sigtap_code, limit: 10, null: false
      t.string :sigtap_competence, limit: 6, null: false
      t.string :priority, null: false, default: "routine"
      t.string :cid10_justification, limit: 4
      t.references :requester_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :requester_name
      t.text :requester_cns
      t.references :unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: false
      t.string :origin, null: false
      t.references :consultation_exam_request, type: :uuid, foreign_key: true, index: { unique: true }
      t.references :exam_provider, type: :uuid, foreign_key: true, index: false
      t.datetime :scheduled_at
      t.string :scheduled_place, limit: 200
      t.string :external_reference, limit: 60
      t.references :guide_file, type: :uuid, foreign_key: { to_table: :exam_files }, index: { unique: true }
      t.string :short_code, limit: 10, null: false
      t.string :status, null: false
      t.datetime :status_changed_at, null: false
      t.string :stage
      t.datetime :stage_opened_at
      t.date :stage_due_on
      t.datetime :escalated_at
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :exam_orders, :short_code, unique: true
    add_index :exam_orders, %i[patient_id created_at], name: "idx_exam_orders_patient_created"
    add_index :exam_orders, %i[unit_id status], name: "idx_exam_orders_unit_status"
    add_index :exam_orders, %i[exam_provider_id status], name: "idx_exam_orders_provider_status"
    add_index :exam_orders, %i[requester_user_id status], name: "idx_exam_orders_requester_status"
    add_index :exam_orders, %i[status stage_due_on], name: "idx_exam_orders_status_due"
    add_check_constraint :exam_orders, "sigtap_code::text ~ '^02[0-9]{8}$'::text", name: "ck_exam_orders_sigtap"
    add_check_constraint :exam_orders, "sigtap_competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text", name: "ck_exam_orders_competence"
    add_check_constraint :exam_orders, "priority::text = ANY (ARRAY['routine'::text, 'urgent'::text])", name: "ck_exam_orders_priority"
    add_check_constraint :exam_orders, "origin::text = ANY (ARRAY['consultation'::text, 'reception_guide'::text, 'pec'::text])", name: "ck_exam_orders_origin"
    add_check_constraint :exam_orders, "status::text = ANY (ARRAY['awaiting_authorization'::text, 'denied'::text, 'awaiting_schedule'::text, 'scheduled'::text, 'collected'::text, 'resulted'::text, 'acknowledged'::text, 'cancelled'::text])",
                         name: "ck_exam_orders_status"
    add_check_constraint :exam_orders, "stage IS NULL OR stage::text = ANY (ARRAY[#{quoted(STAGES)}]::text[])", name: "ck_exam_orders_stage"
    add_check_constraint :exam_orders, "requester_user_id IS NOT NULL OR requester_name IS NOT NULL", name: "ck_exam_orders_requester"
    add_check_constraint :exam_orders, "(origin::text = 'consultation') = (consultation_exam_request_id IS NOT NULL)", name: "ck_exam_orders_consultation"
    add_check_constraint :exam_orders, "origin::text <> 'reception_guide' OR guide_file_id IS NOT NULL", name: "ck_exam_orders_guide"
    add_check_constraint :exam_orders, "short_code::text ~ '^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{10}$'::text", name: "ck_exam_orders_short_code"
    add_check_constraint :exam_orders, "cid10_justification IS NULL OR cid10_justification::text ~ '^[A-Z][0-9]{2}[0-9X]?$'::text",
                         name: "ck_exam_orders_cid10"

    create_table :exam_order_events, id: :uuid do |t|
      t.references :exam_order, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.references :actor_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :actor_provider, type: :uuid, foreign_key: { to_table: :exam_providers }, index: false
      t.text :reason
      t.string :escalation_reason
      t.date :closed_stage_due_on
      t.datetime :occurred_at, null: false
      t.bigint :txid, null: false, default: -> { "txid_current()" }
      t.datetime :created_at, null: false
    end
    add_index :exam_order_events, %i[exam_order_id occurred_at], name: "idx_exam_order_events_order"
    add_index :exam_order_events, %i[kind occurred_at], name: "idx_exam_order_events_kind"
    # A31: no máximo um escalonamento por motivo.
    add_index :exam_order_events, %i[exam_order_id escalation_reason], unique: true, where: "kind::text = 'escalated'",
                                                                       name: "idx_exam_order_events_escalation_once"
    add_check_constraint :exam_order_events, "kind::text = ANY (ARRAY['requested'::text, 'authorized'::text, 'denied'::text, 'scheduled'::text, 'collected'::text, 'resulted'::text, 'acknowledged'::text, 'escalated'::text, 'cancelled'::text])",
                         name: "ck_exam_order_events_kind"
    # A35: portal grava prestador E funcionário; FHIR só o prestador; sem ator só o system (escalated).
    add_check_constraint :exam_order_events, "actor_user_id IS NOT NULL OR actor_provider_id IS NOT NULL OR kind::text = 'escalated'",
                         name: "ck_exam_order_events_actor"
    add_check_constraint :exam_order_events, "kind::text NOT IN ('denied', 'cancelled') OR reason IS NOT NULL", name: "ck_exam_order_events_reason"
    add_check_constraint :exam_order_events, "(kind::text = 'escalated') = (escalation_reason IS NOT NULL)", name: "ck_exam_order_events_escalation"
    add_check_constraint :exam_order_events, "escalation_reason IS NULL OR escalation_reason::text = ANY (ARRAY['overdue'::text, 'critical'::text, 'unlinked_requester'::text])",
                         name: "ck_exam_order_events_escalation_reason"

    create_table :exam_results, id: :uuid do |t|
      t.references :exam_order, type: :uuid, foreign_key: true, index: { unique: true }
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.string :sigtap_code, limit: 10, null: false
      t.string :origin, null: false
      t.string :source, null: false
      t.references :pdf_file, type: :uuid, null: false, foreign_key: { to_table: :exam_files }, index: { unique: true }
      t.text :values, null: false
      t.date :released_on, null: false
      t.string :laboratory_name, limit: 160, null: false
      t.boolean :critical, null: false, default: false
      t.string :fhir_identifier, limit: 128
      t.references :exam_provider, type: :uuid, foreign_key: true, index: false
      t.references :registered_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :registered_by_provider, type: :uuid, foreign_key: { to_table: :exam_providers }, index: false
      t.references :consultation, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :exam_results, %i[patient_id created_at], name: "idx_exam_results_patient_created"
    add_index :exam_results, %i[exam_provider_id fhir_identifier], unique: true, where: "fhir_identifier IS NOT NULL",
                                                                    name: "idx_exam_results_fhir_identifier"
    add_check_constraint :exam_results, "origin::text = ANY (ARRAY['order'::text, 'external'::text])", name: "ck_exam_results_origin"
    add_check_constraint :exam_results, "source::text = ANY (ARRAY['unit'::text, 'provider'::text, 'fhir'::text, 'consultation'::text])", name: "ck_exam_results_source"
    add_check_constraint :exam_results, "(origin::text = 'order') = (exam_order_id IS NOT NULL)", name: "ck_exam_results_order"
    add_check_constraint :exam_results, "(fhir_identifier IS NULL) = (source::text <> 'fhir')", name: "ck_exam_results_fhir"
    # A35: unidade = usuário; FHIR = prestador; portal = os dois.
    add_check_constraint :exam_results, "registered_by_user_id IS NOT NULL OR registered_by_provider_id IS NOT NULL",
                         name: "ck_exam_results_registrant"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'" }.join(", ")

  def days_check = STAGES.map { |stage| "(#{stage}_days IS NULL OR (#{stage}_days BETWEEN 1 AND 365))" }.join(" AND ")
end
