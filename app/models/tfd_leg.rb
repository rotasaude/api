# Trecho do TFD (ADR 0048, Desvio 13): ida ou volta, de frota (com o
# passageiro da viagem) ou de passagem (valor e empresa; acompanhante só
# aqui). A volta aponta a ida (outbound_leg_id). `distance_km` copiado do
# destino. Nunca é apagado (trigger).
class TfdLeg < ApplicationRecord
  belongs_to :tfd_case, inverse_of: :tfd_legs
  belongs_to :transport_trip_passenger, optional: true
  belongs_to :outbound_leg, class_name: "TfdLeg", optional: true, inverse_of: :return_leg
  belongs_to :created_by_user, class_name: "User"
  has_one :return_leg, class_name: "TfdLeg", foreign_key: :outbound_leg_id, inverse_of: :outbound_leg, dependent: :restrict_with_error
  has_many :tfd_allowances, inverse_of: :tfd_leg, dependent: :restrict_with_error

  scope :live, -> { where(voided_at: nil) }

  def done? = done_at.present?
  def voided? = voided_at.present?

  def inspect = "#<TfdLeg id=#{id} direction=#{direction} mode=#{mode}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
