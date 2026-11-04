# Módulo 31 (ADR 0049; contrato §8 e §15 P2; plano, Desvio 11): o BPA do CAPS
# pelo módulo 22. A linha do procedimento realizado ganha a fonte
# `psychosocial`, apontando a ação do CAPS (uma linha por ação: índice único
# parcial). A BPA-C da ação de equipe não tem paciente: `patient_id` passa a
# aceitar nulo só com a ação (CHECK ck_performed_procedures_patient). O CHECK
# não depende do instrumento, porque o Billing::Recalculate o regrava no
# fechamento (um código que perdeu o `01` vira not_bpa sem estourar o CHECK).
# A ação só aparece na fonte `psychosocial`, e a fonte sempre com a ação. O
# trigger rota_performed_procedure_guard já torna a coluna nova imutável (ele
# compara a linha inteira menos as colunas que andam). Irreversível.
class AddPsychosocialBillingSource < ActiveRecord::Migration[8.1]
  SOURCES = %w[attendance consultation lab_report manual tfd psychosocial].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze

  def up
    add_reference :performed_procedures, :psychosocial_action, type: :uuid, foreign_key: true, index: false
    add_index :performed_procedures, :psychosocial_action_id, unique: true, where: "psychosocial_action_id IS NOT NULL",
                                                              name: "idx_performed_procedures_psychosocial_action"
    change_column_null :performed_procedures, :patient_id, true
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
                  "AND ((source::text = 'psychosocial'::text) = (psychosocial_action_id IS NOT NULL))"
    add_check_constraint :performed_procedures, "patient_id IS NOT NULL OR psychosocial_action_id IS NOT NULL",
                         name: "ck_performed_procedures_patient"
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
