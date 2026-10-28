# Andamento do pedido de regulação (ADR 0044): só acréscimo (trigger; a re-cifra
# do motivo passa pela marca de CityEncryption). O motivo é cifrado e não sai
# em inspect, to_s, pretty_print nem as_json.
class RegulationRequestEvent < ApplicationRecord
  encrypts :reason

  belongs_to :regulation_request, inverse_of: :events
  belongs_to :by_user, class_name: "User", optional: true

  def inspect = "#<RegulationRequestEvent id=#{id} regulation_request_id=#{regulation_request_id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "regulation_request_id" => regulation_request_id, "status" => status }
end
