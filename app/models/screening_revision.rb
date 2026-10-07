# Uma revisão da escuta (ADR 0030; spec §3.1): queixa CIAP-2 (com a release),
# sinais vitais, cor sugerida e final. Só acréscimo (trigger).
class ScreeningRevision < ApplicationRecord
  COLORS = %w[red yellow green blue].freeze
  VITAL_COLUMNS = %w[systolic diastolic heart_rate respiratory_rate temperature_c spo2 capillary_glucose glucose_moment
                     weight_kg height_cm pain_score].freeze

  belongs_to :screening
  belongs_to :by_user, class_name: "User"

  def vitals = VITAL_COLUMNS.to_h { |column| [ column, self[column] ] }.compact
end
