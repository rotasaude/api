# Prescrição da observação da UPA (ADR 0050; contrato §5): em versões — a nova
# aponta a anterior (`supersedes`) e no máximo uma está `active` por encontro
# (índice). O status só anda para frente (trigger); o motivo da suspensão é
# cifrado com a chave da cidade. Nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class UrgencyPrescription < ApplicationRecord
  encrypts :suspension_reason

  belongs_to :urgency_encounter, inverse_of: :prescriptions
  belongs_to :supersedes, class_name: "UrgencyPrescription", optional: true
  belongs_to :prescribed_by_user, class_name: "User"
  belongs_to :professional_link
  belongs_to :status_changed_by_user, class_name: "User", optional: true
  has_many :items, -> { order(:position) }, class_name: "UrgencyPrescriptionItem", inverse_of: :urgency_prescription,
                                            dependent: :restrict_with_error

  validates :status, inclusion: { in: Urgency::Catalog::PRESCRIPTION_STATUSES }

  scope :active_versions, -> { where(status: "active") }

  def active? = status == "active"

  def inspect = "#<UrgencyPrescription id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
