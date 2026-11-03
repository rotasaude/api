# Pagamento registrado da ajuda de custo do TFD (ADR 0048): data, valor,
# forma e recibo. Só acréscimo (trigger). Nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class TfdPayment < ApplicationRecord
  belongs_to :tfd_case, inverse_of: :tfd_payments
  belongs_to :by_user, class_name: "User"

  def inspect = "#<TfdPayment id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
