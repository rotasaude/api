# Animal do centro de zoonoses (módulo 35b, ADR 0054; contrato §1, §2, Q22).
# Tutor é sempre um Patient (nunca o nome digitado), só sem community; o
# domicílio é opcional. Microchip cifrado determinístico com a chave da cidade
# (molde do Citizen#cpf): único entre os não nulos e buscável só pelo corpo
# (nunca em URL, log nem ao app). Situação só sai de active e não volta;
# castrado não volta; nunca apagado (trigger). Nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id e a situação.
class Animal < ApplicationRecord
  encrypts :microchip, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  belongs_to :household, optional: true
  belongs_to :tutor_patient, class_name: "Patient", optional: true
  belongs_to :created_by_user, class_name: "User"

  scope :active, -> { where(status: "active") }

  def active? = status == "active"

  def inspect = "#<Animal id=#{id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "status" => status }
end
