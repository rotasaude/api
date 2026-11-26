# Remessa do envio da regulação à RNDS (módulo 26c; Q16, Q17): cada chamada
# (create, replace, delete) de um pedido. O payload é cifrado com a chave da
# cidade (CityEncryption), é NULL no `delete` e vira NULL depois de
# PAYLOAD_DAYS, aceita ou não (Q17); a resposta (`accepted_at`, `rnds_id`,
# `http_status`, `error_codes`, só os códigos) grava-se uma vez; o resto nunca
# muda; nunca é apagada (trigger). O payload não sai em inspect, to_s,
# pretty_print nem as_json.
class RegulationRndsDelivery < ApplicationRecord
  encrypts :payload

  belongs_to :regulation_rnds_sync, inverse_of: :deliveries

  def inspect = "#<RegulationRndsDelivery id=#{id} kind=#{kind} http_status=#{http_status.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
