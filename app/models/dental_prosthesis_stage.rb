# Etapa do pedido de prótese (ADR 0046): trilha só de acréscimo (a re-cifra
# regrava só o motivo, obrigatório no cancelamento). Motivo cifrado, fora de
# inspect, to_s, pretty_print e as_json.
class DentalProsthesisStage < ApplicationRecord
  encrypts :reason

  belongs_to :dental_prosthesis_order, inverse_of: :stages
  belongs_to :by_user, class_name: "User"

  def inspect = "#<DentalProsthesisStage id=#{id} dental_prosthesis_order_id=#{dental_prosthesis_order_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
