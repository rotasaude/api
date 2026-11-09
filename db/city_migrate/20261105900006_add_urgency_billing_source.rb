# Módulo 32a (ADR 0050; contrato §9 e §14 Q12; plano, Task 13): o BPA da
# urgência pelo módulo 22. A linha do procedimento realizado ganha a fonte
# `urgency`, apontando o encontro da UPA: a classificação de risco e o
# atendimento médico, uma linha por código do encontro (índice único
# parcial). O encontro só aparece na fonte `urgency`, e a fonte sempre com o
# encontro. O trigger rota_performed_procedure_guard já torna a coluna nova
# imutável (ele compara a linha inteira menos as colunas que andam), e a fusão
# do provisório (rota_patient_merge_ok) continua trocando só o patient_id: o
# índice novo não tem patient_id. Irreversível.
class AddUrgencyBillingSource < ActiveRecord::Migration[8.1]
  SOURCES = %w[attendance consultation lab_report manual tfd psychosocial urgency].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze

  def up
    add_reference :performed_procedures, :urgency_encounter, type: :uuid, foreign_key: true, index: false
    add_index :performed_procedures, %i[urgency_encounter_id sigtap_code], unique: true, where: "urgency_encounter_id IS NOT NULL",
                                                                           name: "idx_performed_procedures_urgency"
    replace_check :performed_procedures, "ck_performed_procedures_domains",
                  "source::text = ANY (ARRAY[#{quoted(SOURCES)}]::text[]) " \
                  "AND instrument::text = ANY (ARRAY[#{quoted(INSTRUMENTS)}]::text[]) " \
                  "AND character::text = ANY (ARRAY[#{quoted(CHARACTERS)}]::text[]) " \
                  "AND status::text = ANY (ARRAY['recorded'::text, 'cancelled'::text])"
    replace_check :performed_procedures, "ck_performed_procedures_source_ref",
                  "(source::text <> 'attendance'::text OR attendance_id IS NOT NULL) " \
                  "AND (source::text <> 'consultation'::text OR consultation_id IS NOT NULL) " \
                  "AND (source::text <> 'lab_report'::text OR (lab_report_item_id IS NOT NULL AND exam_provider_id IS NOT NULL)) " \
                  "AND (source::text <> 'tfd'::text OR tfd_allowance_id IS NOT NULL) " \
                  "AND ((source::text = 'psychosocial'::text) = (psychosocial_action_id IS NOT NULL)) " \
                  "AND ((source::text = 'urgency'::text) = (urgency_encounter_id IS NOT NULL))"
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
