# Corrida de CIQ do aparelho (ADR 0038): a situação só piora (trigger; Desvio 6).
class LabQcRun < ApplicationRecord
  STATUSES = %w[open approved warning rejected].freeze
  SEVERITY = STATUSES.each_with_index.to_h.freeze
  ACCEPTED = %w[approved warning].freeze

  belongs_to :lab_instrument
  belongs_to :opened_by_user, class_name: "User", optional: true
  has_many :values, -> { order(:entered_at, :created_at) }, class_name: "LabQcValue", inverse_of: :lab_qc_run
end
