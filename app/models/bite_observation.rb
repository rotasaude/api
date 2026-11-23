# Observação do animal agressor (módulo 35b, ADR 0054; contrato §1 e §5, Q16):
# 1:1 com a notificação do 25; estados open e closed (sem cancelled); só vai
# de open a closed, uma vez (trigger). A nota do desfecho é cifrada com a
# chave da cidade. Nunca sai em inspect, to_s, pretty_print nem as_json além
# do id e do estado.
class BiteObservation < ApplicationRecord
  encrypts :outcome_note

  belongs_to :disease_notification
  belongs_to :animal, optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :shelter_stays, inverse_of: :bite_observation, dependent: :restrict_with_error
  has_many :euthanasias, inverse_of: :bite_observation, dependent: :restrict_with_error

  scope :open_observations, -> { where(state: "open") }

  def closed? = state == "closed"

  def inspect = "#<BiteObservation id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
