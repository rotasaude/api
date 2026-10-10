# app/models/patient_medication.rb
# Medicamento em uso do paciente (ADR 0033; spec §5): estado atual resultado de
# patient_medication_events; só Patients::ApplyMedicationEvent escreve aqui
# (trigger exige o evento na mesma transação). Um ativo por paciente + item.
class PatientMedication < ApplicationRecord
  STATUSES = %w[active suspended].freeze
  ORIGINS = %w[prescription external].freeze

  encrypts :free_text
  encrypts :label
  encrypts :dosage_summary

  belongs_to :patient
  has_many :events, class_name: "PatientMedicationEvent", dependent: :restrict_with_error

  scope :active_medications, -> { where(status: "active") }

  def active? = status == "active"
end
