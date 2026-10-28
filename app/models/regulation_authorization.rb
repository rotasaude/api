# Autorização de um pedido de regulação numa oferta (ADR 0044; contrato §13 G1):
# uma linha por autorização. A cota usada da oferta é a contagem das não
# liberadas; cancelar antes do atendimento libera (released_at e
# release_reason, uma vez); falta e atendimento não liberam. Nunca é apagada
# (trigger). O motivo de pular a fila é cifrado e não sai em inspect, to_s,
# pretty_print nem as_json.
class RegulationAuthorization < ApplicationRecord
  encrypts :skip_reason

  belongs_to :regulation_request, inverse_of: :authorizations
  belongs_to :care_offer
  belongs_to :authorized_by_user, class_name: "User"

  scope :unreleased, -> { where(released_at: nil) }

  def inspect = "#<RegulationAuthorization id=#{id} regulation_request_id=#{regulation_request_id} care_offer_id=#{care_offer_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "regulation_request_id" => regulation_request_id, "care_offer_id" => care_offer_id }
end
