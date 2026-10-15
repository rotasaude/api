# Amostra (ADR 0037; spec §4): código de barras = número da requisição + 2
# dígitos. awaiting com collected_at = coletada (Desvio 10).
class LabSample < ApplicationRecord
  STATUSES = %w[awaiting in_transit received rejected accepted_with_restriction not_received].freeze
  ACCEPTED = %w[received accepted_with_restriction].freeze
  MAX_PER_REQUISITION = 99

  belongs_to :lab_requisition
  belongs_to :lab_shipment, optional: true
  belongs_to :lab_rejection_reason, optional: true
  belongs_to :recollection_of, class_name: "LabSample", optional: true
  belongs_to :collected_by_user, class_name: "User", optional: true
  belongs_to :received_by_user, class_name: "User", optional: true
  has_many :items, class_name: "LabRequisitionItem", inverse_of: :lab_sample

  def self.barcode_for(number, index)
    raise ArgumentError, "amostra fora de 1..#{MAX_PER_REQUISITION}" unless index.between?(1, MAX_PER_REQUISITION)

    "#{number}#{format('%02d', index)}"
  end

  def collected? = collected_at.present?
  def accepted? = ACCEPTED.include?(status)
end
