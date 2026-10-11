# Módulo 20 (ADR 0035): linha do tempo do paciente montada na leitura.
# - Índices por pessoa e data nas origens que não tinham (triagens,
#   agendamentos, escutas e problemas já têm caminho indexado).
# - Abertura justificada pela pessoa sem paciente: citizen_id (um par
#   validado do CPF), exatamente um entre patient_id e citizen_id. O trigger
#   clinical_record_openings_reencryption_only segue valendo (citizen_id não
#   é cifrado).
# - Configuração do PEC (linha única; chave HMAC cifrada pela aplicação) e o
#   registro de uso único das assinaturas da página do PEC.
# Tabelas pequenas por cidade: índices sem CONCURRENTLY. Irreversível.
class AddPatientTimeline < ActiveRecord::Migration[8.1]
  def up
    add_index :attendances, %i[citizen_id checked_in_at], name: "idx_attendances_citizen_checked_in"
    add_index :clinical_documents, %i[citizen_id issued_at], name: "idx_clinical_documents_citizen_issued"
    add_index :consultations, %i[patient_id finalized_at], name: "idx_consultations_patient_finalized",
                                                           where: "((status)::text = 'finalized'::text)"
    add_index :campaign_recipients, %i[citizen_id created_at], name: "idx_campaign_recipients_citizen_created"

    change_column_null :clinical_record_openings, :patient_id, true
    add_column :clinical_record_openings, :citizen_id, :uuid
    add_foreign_key :clinical_record_openings, :citizens
    add_index :clinical_record_openings, %i[user_id citizen_id expires_at], name: "idx_clinical_record_openings_valid_citizen"
    add_check_constraint :clinical_record_openings, "(patient_id IS NULL) <> (citizen_id IS NULL)",
                         name: "ck_clinical_record_openings_person"

    create_table :pec_settings, id: :uuid do |t|
      t.boolean :singleton, null: false, default: true
      t.string :pec_origin, limit: 255
      t.text :hmac_key
      t.datetime :pec_origin_updated_at
      t.datetime :hmac_key_updated_at
      t.timestamps
    end
    add_index :pec_settings, :singleton, unique: true, name: "index_pec_settings_singleton"
    add_check_constraint :pec_settings, "singleton", name: "ck_pec_settings_singleton"
    add_check_constraint :pec_settings, "pec_origin IS NULL OR pec_origin::text ~ '^https?://[^/?#@ ]+$'::text",
                         name: "ck_pec_settings_origin"
    add_check_constraint :pec_settings, "(hmac_key IS NULL) = (hmac_key_updated_at IS NULL)",
                         name: "ck_pec_settings_key_updated"

    create_table :pec_signature_uses, id: :uuid do |t|
      t.string :signature_digest, limit: 64, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :pec_signature_uses, :signature_digest, unique: true
    add_index :pec_signature_uses, :expires_at
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
