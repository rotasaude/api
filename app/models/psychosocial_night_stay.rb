# Permanência no leito do acolhimento noturno (ADR 0049): o leito nunca tem
# duas que se cruzam (exclusion GiST, [)); a aberta ocupa até fechar; uma
# aberta por paciente. Aberta só recebe o fechamento (e a reavaliação acima do
# limite, uma vez); fechada congela (trigger). Motivos cifrados com a chave da
# cidade. Dado do paciente nunca sai em inspect, to_s, pretty_print nem as_json
# — só o id.
class PsychosocialNightStay < ApplicationRecord
  encrypts :end_reason, :reassessment_reason

  belongs_to :psychosocial_bed
  belongs_to :health_unit
  belongs_to :psychosocial_enrollment
  belongs_to :patient
  belongs_to :started_by_user, class_name: "User"
  belongs_to :closed_by_user, class_name: "User", optional: true
  belongs_to :reassessed_by_user, class_name: "User", optional: true
  has_many :psychosocial_actions, inverse_of: :psychosocial_night_stay, dependent: :restrict_with_error

  scope :open_stays, -> { where(ended_at: nil) }

  def open? = ended_at.nil?

  def inspect = "#<PsychosocialNightStay id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
