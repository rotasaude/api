# Módulo 27b (BNAFAR; plano, Task 10; contrato §3; Q8, Q14, Q16, Q25; R10,
# R11): o envio diário ao SI-BNAFAR.
#   - bnafar_settings: uma linha só (id 1): o ambiente em uso (fora de
#     produção, o maintenance troca), o primeiro dia enviado (`started_on`, uma
#     vez) e o mantenedor que trocou por último (uuid da plataforma, sem FK);
#   - bnafar_submissions: uma remessa por (dia de referência, assunto,
#     ambiente); a situação agrega as partes `post` (R10);
#   - bnafar_batches: cada chamada à BNAFAR (Q8): `post` (envio e reenvio),
#     `put` (correção) e `delete` (estorno, Q14), com o protocolo, as
#     tentativas e a evidência cURL (só em homologação, trigger);
#   - bnafar_records: um registro por (CNES, item, parte) na posição e um por
#     movimento na saída; o payload cifrado (CityEncryption) vira NULL depois
#     de 30 dias; o `codigoBnafar`, os códigos MSG (só o código, nunca o
#     texto) e a exclusão (`deleted_at`, só em aceito);
#   - bnafar_movement_links: o rastro de cada saída (um por movimento).
# Triggers em db/city_triggers.sql (o dump não representa trigger): nada some,
# a situação só anda para a frente, o payload só vira NULL (ou se re-cifra),
# o `codigoBnafar` gravado não muda. Irreversível.
class AddBnafarSubmissions < ActiveRecord::Migration[8.1]
  # Espelhos de Bnafar::Catalog no dia desta migração (a migração não lê código
  # da aplicação: a lista do banco fica fixa).
  ENVIRONMENTS = %w[homologation production].freeze
  SUBJECTS = %w[position exit].freeze
  SUBMISSION_STATUSES = %w[building queued sending processing finished failed lost].freeze
  BATCH_STATUSES = %w[queued sending processing finished failed].freeze
  BATCH_OPERATIONS = %w[post put delete].freeze
  RECORD_STATUSES = %w[pending accepted rejected].freeze
  LINK_KINDS = %w[exit deletion late_reversal].freeze
  # Bnafar::Catalog::MSG_CODE, em POSIX.
  CODE = "[A-Za-z0-9_-]{2,20}".freeze

  def up
    create_settings
    create_submissions
    create_batches
    create_records
    create_links

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_settings
    create_table :bnafar_settings, id: :smallint do |t|
      t.string :environment, null: false, default: "production"
      t.date :started_on
      t.uuid :updated_by_maintainer_id
      t.datetime :updated_at, null: false
    end
    add_check_constraint :bnafar_settings, "id = 1", name: "ck_bnafar_settings_singleton"
    add_check_constraint :bnafar_settings, in_list("environment", ENVIRONMENTS), name: "ck_bnafar_settings_environment"
    execute "INSERT INTO bnafar_settings (id, environment, updated_at) VALUES (1, 'production', now())"
  end

  def create_submissions
    create_table :bnafar_submissions, id: :uuid do |t|
      t.date :reference_on, null: false
      t.string :subject, null: false
      t.string :environment, null: false
      t.string :status, null: false, default: "building"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :building_started_at
      t.datetime :sent_at
      t.datetime :finished_at
      t.string :last_error, limit: 20
      t.timestamps
    end
    add_index :bnafar_submissions, %i[reference_on subject environment], unique: true, name: "idx_bnafar_submissions_once"
    add_index :bnafar_submissions, %i[status reference_on], name: "idx_bnafar_submissions_status"
    add_check_constraint :bnafar_submissions, in_list("subject", SUBJECTS), name: "ck_bnafar_submissions_subject"
    add_check_constraint :bnafar_submissions, in_list("environment", ENVIRONMENTS), name: "ck_bnafar_submissions_environment"
    add_check_constraint :bnafar_submissions, in_list("status", SUBMISSION_STATUSES), name: "ck_bnafar_submissions_status"
    add_check_constraint :bnafar_submissions, "attempts >= 0", name: "ck_bnafar_submissions_attempts"
    add_check_constraint :bnafar_submissions, "status::text <> 'finished'::text OR finished_at IS NOT NULL", name: "ck_bnafar_submissions_finished"
    add_check_constraint :bnafar_submissions, code_check("last_error"), name: "ck_bnafar_submissions_last_error"
  end

  def create_batches
    create_table :bnafar_batches, id: :uuid do |t|
      t.references :bnafar_submission, type: :uuid, null: false, foreign_key: true, index: true
      t.string :operation, null: false
      t.string :status, null: false, default: "queued"
      t.bigint :protocol
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :last_attempted_at
      t.datetime :sent_at
      t.datetime :finished_at
      t.string :last_error, limit: 20
      t.jsonb :evidence
      t.timestamps
    end
    add_index :bnafar_batches, %i[status next_attempt_at], name: "idx_bnafar_batches_due"
    add_check_constraint :bnafar_batches, in_list("operation", BATCH_OPERATIONS), name: "ck_bnafar_batches_operation"
    add_check_constraint :bnafar_batches, in_list("status", BATCH_STATUSES), name: "ck_bnafar_batches_status"
    add_check_constraint :bnafar_batches, "attempts >= 0", name: "ck_bnafar_batches_attempts"
    add_check_constraint :bnafar_batches, "protocol IS NULL OR protocol > 0", name: "ck_bnafar_batches_protocol"
    add_check_constraint :bnafar_batches, "evidence IS NULL OR jsonb_typeof(evidence) = 'array'::text", name: "ck_bnafar_batches_evidence"
    add_check_constraint :bnafar_batches, code_check("last_error"), name: "ck_bnafar_batches_last_error"
  end

  def create_records
    create_table :bnafar_records, id: :uuid do |t|
      t.references :bnafar_submission, type: :uuid, null: false, foreign_key: true, index: true
      t.references :bnafar_batch, type: :uuid, foreign_key: true, index: true
      t.uuid :origin_code, null: false
      t.string :subject, null: false
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :item_key, null: false, limit: 60
      t.text :payload
      t.bigint :bnafar_code
      t.string :status, null: false, default: "pending"
      t.text :error_codes, array: true, null: false, default: []
      t.integer :rejected_items, null: false, default: 0
      t.references :replaces_record, type: :uuid, foreign_key: { to_table: :bnafar_records }, index: false
      t.references :stock_external_exit, type: :uuid, foreign_key: true, index: false
      t.datetime :sent_at
      t.datetime :accepted_at
      t.datetime :deleted_at
      t.references :deletion_batch, type: :uuid, foreign_key: { to_table: :bnafar_batches }, index: false
      t.timestamps
    end
    add_index :bnafar_records, :origin_code, unique: true, name: "idx_bnafar_records_origin_code"
    add_index :bnafar_records, %i[stock_location_id created_at], name: "idx_bnafar_records_location"
    add_index :bnafar_records, :replaces_record_id, where: "replaces_record_id IS NOT NULL", name: "idx_bnafar_records_replaces"
    add_index :bnafar_records, :stock_external_exit_id, where: "stock_external_exit_id IS NOT NULL", name: "idx_bnafar_records_external_exit"
    add_index :bnafar_records, :deletion_batch_id, where: "deletion_batch_id IS NOT NULL", name: "idx_bnafar_records_deletion_batch"
    add_index :bnafar_records, %i[status accepted_at], name: "idx_bnafar_records_status"
    add_check_constraint :bnafar_records, in_list("subject", SUBJECTS), name: "ck_bnafar_records_subject"
    add_check_constraint :bnafar_records, in_list("status", RECORD_STATUSES), name: "ck_bnafar_records_status"
    add_check_constraint :bnafar_records, "rejected_items >= 0", name: "ck_bnafar_records_rejected_items"
    add_check_constraint :bnafar_records, "bnafar_code IS NULL OR bnafar_code > 0 AND status::text = 'accepted'::text",
                         name: "ck_bnafar_records_code"
    add_check_constraint :bnafar_records, "(status::text = 'accepted'::text) = (accepted_at IS NOT NULL)", name: "ck_bnafar_records_accepted"
    add_check_constraint :bnafar_records, "(deleted_at IS NULL AND deletion_batch_id IS NULL) OR status::text = 'accepted'::text",
                         name: "ck_bnafar_records_deletion"
    add_check_constraint :bnafar_records, "deleted_at IS NULL OR deletion_batch_id IS NOT NULL", name: "ck_bnafar_records_deleted_by_batch"
    add_check_constraint :bnafar_records,
                         "array_position(error_codes, NULL::text) IS NULL AND " \
                         "array_to_string(error_codes, ','::text) ~ '^(#{CODE}(,#{CODE})*)?$'::text",
                         name: "ck_bnafar_records_error_codes"
  end

  def create_links
    create_table :bnafar_movement_links, id: :uuid do |t|
      t.references :stock_movement, type: :uuid, null: false, foreign_key: true, index: false
      t.references :bnafar_record, type: :uuid, null: false, foreign_key: true, index: true
      t.string :kind, null: false
      t.datetime :created_at, null: false
    end
    add_index :bnafar_movement_links, :stock_movement_id, unique: true, name: "idx_bnafar_movement_links_movement"
    add_check_constraint :bnafar_movement_links, in_list("kind", LINK_KINDS), name: "ck_bnafar_movement_links_kind"
  end

  def in_list(column, list) = "#{column}::text = ANY (ARRAY[#{list.map { |value| "'#{value}'::text" }.join(', ')}])"
  def code_check(column) = "#{column} IS NULL OR #{column}::text ~ '^#{CODE}$'::text"
end
