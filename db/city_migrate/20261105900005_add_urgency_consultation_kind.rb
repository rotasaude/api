# Módulo 32a (ADR 0050; contrato §7 e §14 Q10; plano, Desvio 14): o
# atendimento médico na UPA é a consulta do 19a com `kind: "urgency"`. Ela
# fica fora do LEDI e da produção da APS: nunca grava tipo de atendimento
# (ck_consultations_care_type não muda: o tipo só vale casado com `general` ou
# `dental`, então a urgência só aceita nulo) e finaliza sem ele
# (ck_consultations_finalized_care_type). Os campos da FAO continuam só na
# `dental` (ck_consultations_dental_fields já aceita qualquer kind não dental
# com os campos vazios; não muda).
#
# Documentos do walk_in (19c): a pessoa do walk_in é o paciente, sem par do
# wpda, então o documento da consulta de urgência nasce sem `citizen_id`
# (ck_clinical_documents_citizen passa a aceitar). O documento sem cidadão e
# sem ação do CAPS exige o paciente, e o rota_clinical_document_guard
# (db/city_triggers.sql, executado no fim) recusa esse documento fora de um
# atendimento walk_in. Irreversível.
class AddUrgencyConsultationKind < ActiveRecord::Migration[8.1]
  def up
    replace_check :consultations, "ck_consultations_kind", "kind::text = ANY (ARRAY['general'::text, 'dental'::text, 'urgency'::text])"
    replace_check :consultations, "ck_consultations_finalized_care_type",
                  "status::text <> 'finalized'::text OR care_type IS NOT NULL OR baseline OR kind::text = 'urgency'::text"
    replace_check :clinical_documents, "ck_clinical_documents_citizen",
                  "(psychosocial_action_id IS NULL OR citizen_id IS NULL) " \
                  "AND (psychosocial_action_id IS NOT NULL OR citizen_id IS NOT NULL OR patient_id IS NOT NULL)"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
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
