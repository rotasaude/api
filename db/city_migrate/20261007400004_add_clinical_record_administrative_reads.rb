# db/city_migrate/20261007400004_add_clinical_record_administrative_reads.rb
# Task 23 do módulo 19 (decisão do usuário 2026-10-09; contrato §9): cada
# leitura administrativa de consulta (municipal_admin) fica guardada PARA
# SEMPRE em tabela própria, como as aberturas — o evento clinical_record.viewed
# é purgado após 12 meses (PurgeDomainEventsJob) e o relatório das aberturas
# perderia a leitura. Só ids (nada cifrado, fora de CITY_KEYED_TARGETS); só
# acréscimo, sem exceção de re-cifra nem de exclusão LGPD (ADR 0026: paciente
# atendido é retido, como em clinical_record_openings).
class AddClinicalRecordAdministrativeReads < ActiveRecord::Migration[8.1]
  def up
    create_table :clinical_record_administrative_reads, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.uuid :patient_id, null: false
      t.uuid :consultation_id, null: false
      t.datetime :created_at, null: false, default: -> { "now()" }
    end
    add_index :clinical_record_administrative_reads, %i[created_at id], name: "idx_clinical_record_administrative_reads_report"
    add_index :clinical_record_administrative_reads, :user_id
    add_index :clinical_record_administrative_reads, :consultation_id
    add_foreign_key :clinical_record_administrative_reads, :users
    add_foreign_key :clinical_record_administrative_reads, :patients
    add_foreign_key :clinical_record_administrative_reads, :consultations

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
