# Abertura justificada do prontuário fora de contexto (ADR 0031; spec §5):
# motivo de lista, nota (cifrada) só com `other`, válida 30 minutos para
# aquele usuário e paciente. Só acréscimo.
class ClinicalRecordOpening < ApplicationRecord
  REASONS = %w[case_review active_search continuity_of_care other].freeze
  VALIDITY = 30.minutes
  MIN_NOTE = 10
  MAX_NOTE = 500

  encrypts :reason_note

  belongs_to :patient
  belongs_to :user

  scope :valid_for, ->(user_id:, patient_id:, now: Time.current) {
    where(user_id: user_id, patient_id: patient_id).where("expires_at > ?", now)
  }
end
