# app/models/patient_medication_event.rb
# Um evento da lista de medicamentos (ADR 0033): só acréscimo, ligado a UMA
# consulta, adendo ou documento. O txid amarra o evento à transação do estado.
class PatientMedicationEvent < ApplicationRecord
  KINDS = %w[added suspended reactivated changed].freeze

  encrypts :dosage_summary

  # Opcional no modelo: o evento nasce ANTES do medicamento novo (FK DEFERRABLE).
  belongs_to :patient_medication, optional: true
  belongs_to :user
end
