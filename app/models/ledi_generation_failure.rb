# Ficha que não pôde nascer por falta de identificação (ADR 0030; spec §5).
# Uma aberta por fonte; "gerar de novo" tenta e resolve.
class LediGenerationFailure < ApplicationRecord
  REASONS = %w[unit_without_cnes professional_without_team professional_without_cns citizen_without_birth_date
               citizen_without_sex unknown_ciap2].freeze

  scope :unresolved, -> { where(resolved_at: nil) }

  validates :reason_codes, presence: true

  def resolved? = resolved_at.present?
end
