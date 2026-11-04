# Matrícula no CAPS (ADR 0049): uma aberta por paciente e CAPS (índice
# parcial). CID principal, CIDs secundários e substâncias (JSON) cifrados com a
# chave da cidade. Encerrar grava destino (nunca `00`), data e quem encerrou
# (CHECK). Nunca é apagada (trigger). Dado do paciente nunca sai em inspect,
# to_s, pretty_print nem as_json — só o id.
class PsychosocialEnrollment < ApplicationRecord
  serialize :cid_secondary, coder: JSON
  serialize :substances, coder: JSON
  encrypts :cid_main, :cid_secondary, :substances

  belongs_to :health_unit
  belongs_to :patient
  belongs_to :psychosocial_reception, optional: true
  belongs_to :reference_user, class_name: "User"
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :psychosocial_care_plans, -> { order(:version) }, inverse_of: :psychosocial_enrollment, dependent: :restrict_with_error
  has_many :psychosocial_monthly_records, inverse_of: :psychosocial_enrollment, dependent: :restrict_with_error
  has_many :psychosocial_night_stays, inverse_of: :psychosocial_enrollment, dependent: :restrict_with_error
  has_many :psychosocial_action_participants, inverse_of: :psychosocial_enrollment, dependent: :restrict_with_error

  scope :open_enrollments, -> { where(closed_on: nil) }

  def open? = closed_on.nil?

  def inspect = "#<PsychosocialEnrollment id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
