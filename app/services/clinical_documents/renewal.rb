# app/services/clinical_documents/renewal.rb
# "Renovar receita" (spec §5): os contínuos ATIVOS do paciente, na forma do
# <item> (contrato §2), com a última posologia receitada do mesmo item do
# catálogo (o informado de fora vem só com o resumo). É só um rascunho para
# revisão: a emissão valida tudo de novo.
module ClinicalDocuments
  module Renewal
    module_function

    def items(consultation)
      medications = PatientMedication.where(patient_id: consultation.patient_id, status: "active", continuous: true)
                                     .order(:created_at, :id).to_a
      catalog = MedicationCatalogItem.where(id: medications.filter_map(&:catalog_item_id)).index_by(&:id)
      last = PrescriptionItem.joins(:clinical_document)
                             .where(clinical_documents: { patient_id: consultation.patient_id, status: "issued" },
                                    medication_catalog_item_id: catalog.keys)
                             .order(created_at: :desc, id: :desc).to_a.uniq(&:medication_catalog_item_id)
                             .index_by(&:medication_catalog_item_id)
      medications.each_with_index.map do |medication, index|
        item = catalog[medication.catalog_item_id]
        prior = medication.catalog_item_id && last[medication.catalog_item_id]
        { position: index + 1, catalog_item: item && Json.catalog_ref(item).merge(Json.catalog_marks(item)),
          free_text: medication.free_text, printed_description: medication.label,
          quantity: prior && Json.number(prior.quantity), quantity_unit: prior&.quantity_unit,
          route: prior&.route, dosage_instructions: prior&.dosage_instructions || medication.dosage_summary,
          duration_days: prior&.duration_days, continuous: true, antimicrobial: item&.antimicrobial || false,
          reason_problem_id: prior&.reason_problem_id }.compact
      end
    end
  end
end
