# db/city_migrate/20261008500001_add_digital_signatures.rb
# Assinatura digital do prontuário (ADR 0032; spec §4). O certificado
# vinculado, a sessão do turno, o state de uso único do OAuth, o pedido (a
# fila) e a assinatura (só acréscimo). O banco garante: um certificado e uma
# sessão ativos por usuário, um pedido por documento, uma assinatura por pedido
# e por documento, assinatura gravada nunca muda (só a validação e a re-cifra),
# pedido resolvido nunca volta. As tabelas do 19a não mudam.
#
# `simulated` = o PSC simulado de desenvolvimento (interruptor
# signature_psc_mock, nunca em produção): a assinatura guarda o provedor para
# dizer, sem decifrar nada, que é simulada e sem validade jurídica.
class AddDigitalSignatures < ActiveRecord::Migration[8.1]
  PROVIDERS = %w[vidaas birdid safeid neoid remoteid simulated].freeze
  REASONS = %w[no_session session_expired provider_unavailable provider_rejected signer_unavailable verification_failed
               certificate_expired certificate_revoked certificate_cpf_mismatch feature_disabled user_request].freeze
  DOCUMENT_TYPES = %w[Consultation ConsultationAddendum].freeze

  def text_in(column, values) = "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"

  def checks(table, map) = map.each { |name, expression| add_check_constraint table, expression, name: name }

  def up
    create_table :signer_certificates, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :provider, null: false
      t.string :certificate_alias, null: false
      t.string :serial_number, null: false
      t.text :issuer_dn, null: false
      t.text :subject_cpf, null: false
      t.datetime :not_before, null: false
      t.datetime :not_after, null: false
      t.string :status, null: false, default: "active"
      t.text :certificate_der, null: false
      # Resultado do POST /certificates/check do signer no vínculo (indeterminate =
      # LCR fora do ar; a revogação volta a ser conferida na primeira assinatura).
      t.string :link_check_status, null: false, default: "valid"
      t.string :link_check_reasons, array: true, null: false, default: []
      t.timestamps
    end
    add_index :signer_certificates, :user_id, unique: true, where: "((status)::text = 'active'::text)",
                                              name: "idx_signer_certificates_one_active"
    add_index :signer_certificates, :user_id
    add_foreign_key :signer_certificates, :users
    checks(:signer_certificates,
           "ck_signer_certificates_provider" => text_in("provider", PROVIDERS),
           "ck_signer_certificates_status" => text_in("status", %w[active replaced unlinked revoked expired]),
           "ck_signer_certificates_validity" => "not_after > not_before",
           "ck_signer_certificates_link_check" => text_in("link_check_status", %w[valid indeterminate]))

    create_table :signature_sessions, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.uuid :signer_certificate_id, null: false
      t.string :provider, null: false
      t.text :access_token, null: false
      t.string :scope, null: false
      t.datetime :started_at, null: false
      t.datetime :expires_at, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :signature_sessions, :user_id, unique: true, where: "((status)::text = 'active'::text)",
                                             name: "idx_signature_sessions_one_active"
    add_index :signature_sessions, :signer_certificate_id
    add_foreign_key :signature_sessions, :users
    add_foreign_key :signature_sessions, :signer_certificates
    checks(:signature_sessions,
           "ck_signature_sessions_provider" => text_in("provider", PROVIDERS),
           "ck_signature_sessions_status" => text_in("status", %w[active expired revoked]),
           "ck_signature_sessions_scope" => "scope::text = 'signature_session'::text",
           "ck_signature_sessions_lifetime" => "expires_at > started_at AND expires_at <= (started_at + '12:00:00'::interval)")

    create_table :signature_oauth_states, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :purpose, null: false
      t.string :provider, null: false
      t.text :code_verifier, null: false
      t.uuid :request_ids, array: true, null: false, default: []
      t.string :return_to, null: false, default: "/"
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :created_at, null: false
    end
    add_index :signature_oauth_states, :user_id
    add_index :signature_oauth_states, :expires_at
    add_foreign_key :signature_oauth_states, :users
    checks(:signature_oauth_states,
           "ck_signature_oauth_states_purpose" => text_in("purpose", %w[link session batch]),
           "ck_signature_oauth_states_provider" => text_in("provider", PROVIDERS),
           "ck_signature_oauth_states_batch" => "((purpose)::text = 'batch'::text) = (cardinality(request_ids) > 0) AND cardinality(request_ids) <= 50",
           "ck_signature_oauth_states_return_to" => "(return_to)::text ~ '^/([^/\\\\][^\\\\]*)?$'::text")

    create_table :signature_requests, id: :uuid do |t|
      t.string :document_type, null: false
      t.uuid :document_id, null: false
      t.uuid :consultation_id, null: false
      t.uuid :author_user_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :reason_code
      t.text :return_note
      t.integer :attempts, null: false, default: 0
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :signature_requests, %i[document_type document_id], unique: true, name: "idx_signature_requests_document"
    add_index :signature_requests, %i[author_user_id status created_at], name: "idx_signature_requests_queue"
    add_index :signature_requests, :consultation_id
    add_foreign_key :signature_requests, :users, column: :author_user_id
    checks(:signature_requests,
           "ck_signature_requests_document_type" => text_in("document_type", DOCUMENT_TYPES),
           "ck_signature_requests_status" => text_in("status", %w[pending signed failed returned_to_paper]),
           "ck_signature_requests_reason" => "reason_code IS NULL OR #{text_in('reason_code', REASONS)}",
           "ck_signature_requests_attempts" => "attempts >= 0",
           "ck_signature_requests_resolution" => "(#{text_in('status', %w[signed returned_to_paper])}) = (resolved_at IS NOT NULL)",
           "ck_signature_requests_return_note" => "(status)::text = 'returned_to_paper'::text OR return_note IS NULL")

    create_table :signatures, id: :uuid do |t|
      t.uuid :signature_request_id, null: false
      t.string :document_type, null: false
      t.uuid :document_id, null: false
      t.text :canonical_json, null: false
      t.string :canonical_sha256, null: false
      t.text :cades, null: false
      t.text :signed_pdf, null: false
      t.string :pdf_sha256, null: false
      t.string :policy, null: false, default: "AD-RB"
      t.string :policy_oid, null: false
      t.string :provider, null: false
      t.text :validation_material, null: false
      t.uuid :signer_certificate_id, null: false
      t.text :signer_cpf, null: false
      t.datetime :signed_at, null: false
      t.string :last_verification, null: false
      t.datetime :last_verification_at, null: false
      t.string :last_verification_reasons, array: true, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :signatures, :signature_request_id, unique: true
    add_index :signatures, %i[document_type document_id], unique: true, name: "idx_signatures_document"
    add_index :signatures, :signer_certificate_id
    add_index :signatures, :last_verification
    add_foreign_key :signatures, :signature_requests
    add_foreign_key :signatures, :signer_certificates
    checks(:signatures,
           "ck_signatures_document_type" => text_in("document_type", DOCUMENT_TYPES),
           "ck_signatures_policy" => text_in("policy", %w[AD-RB AD-RT]),
           "ck_signatures_provider" => text_in("provider", PROVIDERS),
           "ck_signatures_verification" => text_in("last_verification", %w[valid invalid indeterminate]),
           "ck_signatures_sha256" => "(canonical_sha256)::text ~ '^[0-9a-f]{64}$'::text AND (pdf_sha256)::text ~ '^[0-9a-f]{64}$'::text")

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
