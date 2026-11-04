# Módulo 31 (ADR 0049; contrato §9, §15 P8 e P28; plano, Desvio 12): a
# receita, a notificação de controlado e o atestado do 19 emitidos a partir da
# ação do CAPS, sem atendimento e sem cidadão. O documento aponta OU o
# atendimento OU a ação (ck_clinical_documents_parent; com a ação, nunca a
# consulta), e o `citizen_id` é nulo exatamente quando há ação
# (ck_clinical_documents_citizen) — o que o tira do wpda, da linha do tempo e
# das consultas pelo par. Os três CHECKs que exigiam a consulta aceitam a ação
# como alternativa. O pedido de assinatura do 19b (P28) aceita o documento
# clínico sem consulta; consulta e adendo seguem com ela, o laudo sem. O
# trigger rota_clinical_document_guard compara a linha inteira e já torna a
# coluna nova imutável. Irreversível.
class AddPsychosocialDocuments < ActiveRecord::Migration[8.1]
  def up
    add_reference :clinical_documents, :psychosocial_action, type: :uuid, foreign_key: true, index: true
    change_column_null :clinical_documents, :attendance_id, true
    change_column_null :clinical_documents, :citizen_id, true
    add_check_constraint :clinical_documents,
                         "num_nonnulls(attendance_id, psychosocial_action_id) = 1 " \
                         "AND (psychosocial_action_id IS NULL OR consultation_id IS NULL)",
                         name: "ck_clinical_documents_parent"
    add_check_constraint :clinical_documents, "(psychosocial_action_id IS NULL) = (citizen_id IS NOT NULL)",
                         name: "ck_clinical_documents_citizen"
    replace_check :clinical_documents, "ck_clinical_documents_consultation",
                  "consultation_id IS NOT NULL OR psychosocial_action_id IS NOT NULL " \
                  "OR kind::text = 'attendance_declaration'::text"
    replace_check :clinical_documents, "ck_clinical_documents_paper_outside_consultation",
                  "consultation_id IS NOT NULL OR psychosocial_action_id IS NOT NULL OR issue_mode::text = 'paper'::text"
    replace_check :clinical_documents, "ck_clinical_documents_cbo_required",
                  "(consultation_id IS NULL AND psychosocial_action_id IS NULL) OR cbo_code IS NOT NULL"
    replace_check :signature_requests, "ck_signature_requests_consultation",
                  "(document_type::text = 'LabReport'::text AND consultation_id IS NULL) " \
                  "OR (document_type::text = ANY (ARRAY['Consultation'::text, 'ConsultationAddendum'::text]) " \
                  "AND consultation_id IS NOT NULL) " \
                  "OR document_type::text = 'ClinicalDocument'::text"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
