# Motorista (ADR 0048): 1:1 com o usuário de papel `driver`, com a CNH
# (número cifrado com a chave da cidade, categoria e validade). Nunca é apagado
# (trigger): desativa-se. O número da CNH nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class TransportDriver < ApplicationRecord
  encrypts :license_number

  belongs_to :user, inverse_of: :transport_driver
  belongs_to :updated_by_user, class_name: "User"
  has_many :transport_trips, inverse_of: :transport_driver, dependent: :restrict_with_error

  def inspect = "#<TransportDriver id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
