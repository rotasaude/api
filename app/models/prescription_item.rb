# app/models/prescription_item.rb
# Item da receita (ADR 0033; spec §5): nasce com o documento, nunca muda. Do
# catálogo (código e release da emissão) OU texto livre (marcado).
class PrescriptionItem < ApplicationRecord
  ROUTES = %w[oral sublingual topical ophthalmic otic nasal inhalation vaginal rectal intramuscular intravenous
              subcutaneous other].freeze

  encrypts :free_text
  encrypts :printed_description
  encrypts :dosage_instructions

  belongs_to :clinical_document, inverse_of: :prescription_items
  belongs_to :reason_problem, class_name: "PatientProblem", optional: true
  belongs_to :nursing_protocol_version_item, optional: true
end
