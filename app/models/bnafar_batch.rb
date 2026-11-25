# Uma chamada à BNAFAR de uma remessa (módulo 27b; Q8, Q14): `post` (envio ou
# reenvio), `put` (correção) ou `delete` (estorno), com o protocolo, as
# tentativas e a evidência cURL (só em homologação, trigger; sem token nem
# senha). A evidência e o corpo não saem em inspect, to_s, pretty_print nem
# as_json.
class BnafarBatch < ApplicationRecord
  belongs_to :bnafar_submission, inverse_of: :batches
  has_many :records, class_name: "BnafarRecord", inverse_of: :bnafar_batch

  def inspect = "#<BnafarBatch id=#{id} operation=#{operation} status=#{status} protocol=#{protocol.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
