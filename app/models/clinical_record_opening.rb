# Abertura justificada do prontuário fora de contexto (ADR 0031; spec §5):
# motivo de lista, nota (cifrada) só com `other`, válida 30 minutos para
# aquele usuário e paciente. Só acréscimo.
class ClinicalRecordOpening < ApplicationRecord
  REASONS = %w[case_review active_search continuity_of_care other].freeze
  VALIDITY = 30.minutes
  MIN_NOTE = 10
  MAX_NOTE = 500

  encrypts :reason_note

  # ADR 0035: a abertura é de um paciente (19a) ou, sem paciente, de um par
  # validado do CPF (exatamente um dos dois; CHECK no banco).
  belongs_to :patient, optional: true
  belongs_to :citizen, optional: true
  belongs_to :user

  scope :valid_for, ->(user_id:, patient_id:, now: Time.current) {
    where(user_id: user_id, patient_id: patient_id).where("expires_at > ?", now)
  }

  # ADR 0035: abertura válida da pessoa — do paciente ou de um par dela.
  scope :valid_for_person, ->(user_id:, person:, now: Time.current) {
    base = where(user_id: user_id).where("expires_at > ?", now)
    by_pair = base.where(citizen_id: person.citizen_ids)
    person.patient_id ? base.where(patient_id: person.patient_id).or(by_pair) : by_pair
  }
end
