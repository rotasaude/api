# Versão do Projeto Terapêutico Singular (ADR 0049): só acréscimo (trigger) —
# a revisão grava a versão seguinte. Necessidades e objetivos (JSON) cifrados
# com a chave da cidade. Dado do paciente nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class PsychosocialCarePlan < ApplicationRecord
  serialize :goals, coder: JSON
  encrypts :needs, :goals

  belongs_to :psychosocial_enrollment
  belongs_to :created_by_user, class_name: "User"
  has_one :psychosocial_care_plan_alert, inverse_of: :psychosocial_care_plan, dependent: :restrict_with_error

  def inspect = "#<PsychosocialCarePlan id=#{id} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
