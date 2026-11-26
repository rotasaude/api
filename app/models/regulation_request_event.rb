# Andamento do pedido de regulação (ADR 0044): só acréscimo (trigger; a re-cifra
# do motivo passa pela marca de CityEncryption). O motivo é cifrado e não sai
# em inspect, to_s, pretty_print nem as_json. Módulo 26c (Q24): a linha
# `missed` guarda o horário (`scheduled_at`, `ends_at`) e o prestador
# (`care_provider_id`) que a falta limpou do pedido; nulos nas outras linhas.
class RegulationRequestEvent < ApplicationRecord
  encrypts :reason

  belongs_to :regulation_request, inverse_of: :events
  belongs_to :by_user, class_name: "User", optional: true
  belongs_to :care_provider, optional: true

  def inspect = "#<RegulationRequestEvent id=#{id} regulation_request_id=#{regulation_request_id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "regulation_request_id" => regulation_request_id, "status" => status }
end
