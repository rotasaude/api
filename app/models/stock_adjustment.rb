# Ajuste, perda ou vencimento (ADR 0045). Ajuste acima do limite fica pending
# e é decidido uma vez, por outro usuário (CHECK e trigger); perda e
# vencimento nascem applied. Motivos cifrados, fora de inspect, to_s,
# pretty_print e as_json.
class StockAdjustment < ApplicationRecord
  encrypts :reason, :decision_reason

  belongs_to :stock_location
  belongs_to :stock_lot
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :decided_by_user, class_name: "User", optional: true

  def inspect = "#<StockAdjustment id=#{id} kind=#{kind} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
