# Ação do CAPS (ADR 0049): procedimento SIGTAP com o instrumento decidido na
# gravação (raas_psi, bpa_i ou bpa_c), o profissional e o CBO do vínculo, o mês
# local (dia 1º) e os participantes. Imutável: só o cancelamento, uma vez; não
# nasce em mês fechado (trigger). Evolução e motivo do cancelamento cifrados
# com a chave da cidade. Dado do paciente nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class PsychosocialAction < ApplicationRecord
  encrypts :notes, :cancel_reason

  belongs_to :health_unit
  belongs_to :psychosocial_group, optional: true
  belongs_to :professional_user, class_name: "User"
  belongs_to :psychosocial_night_stay, optional: true
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  has_many :psychosocial_action_participants, -> { order(:position) }, inverse_of: :psychosocial_action,
                                                                         dependent: :restrict_with_error

  scope :active, -> { where(cancelled_at: nil) }

  def cancelled? = cancelled_at.present?

  def inspect = "#<PsychosocialAction id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
