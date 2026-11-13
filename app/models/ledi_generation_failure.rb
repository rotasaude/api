# Ficha que não pôde nascer por falta de identificação (ADR 0030; spec §5).
# Uma aberta por fonte; "gerar de novo" tenta e resolve. Módulo 24b (Q4; plano,
# Desvio 9): as fichas 8 e 6 reusam os de nascimento e sexo e acrescentam o prazo
# do SIAPS e os do participante e do local da atividade coletiva.
class LediGenerationFailure < ApplicationRecord
  REASONS = %w[unit_without_cnes professional_without_team professional_without_cns citizen_without_birth_date
               citizen_without_sex unknown_ciap2 regeneration_refused still_sending
               patient_without_identifier responsible_without_identifier cbo_not_in_ledi_table
               city_profile_incomplete too_many_procedure_codes quantity_exceeds_location_limit
               siaps_deadline_passed participant_without_identifier participant_without_birth_date
               participant_without_sex participant_professional_without_cns place_without_cnes].freeze

  scope :unresolved, -> { where(resolved_at: nil) }

  validates :reason_codes, presence: true

  def resolved? = resolved_at.present?
end
