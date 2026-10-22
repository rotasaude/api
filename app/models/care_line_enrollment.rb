# app/models/care_line_enrollment.rb
# Inscrição confirmada por profissional (ADR 0040). anchor_date (DUM) e a
# nota de encerramento cifradas com a chave da cidade.
class CareLineEnrollment < ApplicationRecord
  encrypts :anchor_date, :ended_note

  belongs_to :patient
  belongs_to :care_line
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :enrolled_by_user, class_name: "User"
  belongs_to :ended_by_user, class_name: "User", optional: true
  belongs_to :suggestion, class_name: "CareLineSuggestion", optional: true
  has_many :contacts, -> { order(recorded_at: :desc, id: :desc) }, class_name: "CareOutreachContact", foreign_key: :enrollment_id,
                                                                   dependent: :restrict_with_error, inverse_of: :enrollment

  scope :active_enrollments, -> { where(status: "active") }

  def active? = status == "active"
  def anchor_on = anchor_date.present? ? Date.iso8601(anchor_date) : nil
end
