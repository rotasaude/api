# db/city_migrate/20261010700001_add_controlled_prescriptions.rb
# Receita de controlado e antimicrobiano com SNCR (ADR 0034; spec 2026-10-10
# §3–§5). Estoque de números por prescritor (lotes só acréscimo; número
# free → used → voided por trigger, único por tipo e modo), endereço do prescritor
# (cifrado), o documento controlled_notification_record (sempre papel) e os
# propósitos do state do SNCR no state de uso único do 19b. Triggers em
# db/city_triggers.sql. Irreversível.
class AddControlledPrescriptions < ActiveRecord::Migration[8.1]
  KINDS = %w[sick_note attendance_declaration prescription exam_requisition controlled_notification_record].freeze
  PURPOSES = %w[link session batch sncr_rce sncr_ret].freeze
  PAPER_REASONS = %w[no_certificate signature_unavailable no_sncr_number nurse_antimicrobial feature_disabled free_text_items].freeze
  # A lista do 19b (conferida na Task 0, Step 6) somada aos provedores do SNCR.
  PROVIDERS = %w[vidaas birdid safeid neoid remoteid simulated sncr sncr_simulated].freeze

  def text_in(column, values) = "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"

  def up
    create_table :sncr_number_batches, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :kind, null: false
      t.string :first_number, null: false
      t.string :last_number, null: false
      t.integer :quantity, null: false
      t.date :month, null: false
      t.integer :month_request, null: false
      t.boolean :simulated, null: false
      t.datetime :requested_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :sncr_number_batches, %i[user_id kind month], name: "idx_sncr_number_batches_month"
    add_foreign_key :sncr_number_batches, :users
    add_check_constraint :sncr_number_batches, text_in("kind", %w[rce ret]), name: "ck_sncr_number_batches_kind"
    add_check_constraint :sncr_number_batches, "quantity BETWEEN 1 AND 1000", name: "ck_sncr_number_batches_quantity"
    add_check_constraint :sncr_number_batches, "month_request >= 1", name: "ck_sncr_number_batches_month_request"
    add_check_constraint :sncr_number_batches, "month = date_trunc('month', month)::date", name: "ck_sncr_number_batches_month"

    create_table :sncr_numbers, id: :uuid do |t|
      t.string :kind, null: false
      t.string :number, null: false
      t.uuid :batch_id, null: false
      t.uuid :user_id, null: false
      t.boolean :simulated, null: false
      t.string :status, null: false, default: "free"
      t.uuid :document_id
      t.datetime :used_at
      t.datetime :voided_at
      t.datetime :created_at, null: false
    end
    add_index :sncr_numbers, %i[kind number simulated], unique: true, name: "idx_sncr_numbers_kind_number_simulated"
    add_index :sncr_numbers, %i[user_id kind simulated number], where: "status = 'free'", name: "idx_sncr_numbers_free"
    add_index :sncr_numbers, :document_id, unique: true, where: "document_id IS NOT NULL", name: "idx_sncr_numbers_document"
    add_index :sncr_numbers, :batch_id
    add_foreign_key :sncr_numbers, :sncr_number_batches, column: :batch_id
    add_foreign_key :sncr_numbers, :users
    add_foreign_key :sncr_numbers, :clinical_documents, column: :document_id
    add_check_constraint :sncr_numbers, text_in("kind", %w[rce ret]), name: "ck_sncr_numbers_kind"
    add_check_constraint :sncr_numbers, text_in("status", %w[free used voided]), name: "ck_sncr_numbers_status"
    add_check_constraint :sncr_numbers, "number::text ~ '^[0-9]{4}\\.[0-9]-[0-9]{2}\\.[0-9]{7}$'::text", name: "ck_sncr_numbers_format"
    add_check_constraint :sncr_numbers,
                         "(status::text = 'free'::text) = (document_id IS NULL) AND (status::text = 'free'::text) = (used_at IS NULL) " \
                         "AND (status::text = 'voided'::text) = (voided_at IS NOT NULL)",
                         name: "ck_sncr_numbers_state"

    add_column :professionals, :prescriber_address, :text

    remove_check_constraint :clinical_documents, name: "ck_clinical_documents_kind"
    add_check_constraint :clinical_documents, text_in("kind", KINDS), name: "ck_clinical_documents_kind"
    add_check_constraint :clinical_documents,
                         "kind::text <> 'controlled_notification_record'::text OR issue_mode::text = 'paper'::text",
                         name: "ck_clinical_documents_notification_paper"
    # Desvio 10: o motivo do papel é gravado (nulo no digital e onde não se aplica).
    add_column :clinical_documents, :paper_reason, :string
    add_check_constraint :clinical_documents, "paper_reason IS NULL OR #{text_in('paper_reason', PAPER_REASONS)}",
                         name: "ck_clinical_documents_paper_reason"
    add_check_constraint :clinical_documents, "paper_reason IS NULL OR issue_mode::text = 'paper'::text",
                         name: "ck_clinical_documents_paper_reason_mode"

    remove_check_constraint :signature_oauth_states, name: "ck_signature_oauth_states_purpose"
    add_check_constraint :signature_oauth_states, text_in("purpose", PURPOSES), name: "ck_signature_oauth_states_purpose"
    remove_check_constraint :signature_oauth_states, name: "ck_signature_oauth_states_provider"
    add_check_constraint :signature_oauth_states, text_in("provider", PROVIDERS), name: "ck_signature_oauth_states_provider"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
