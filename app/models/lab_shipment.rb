# Remessa de amostras da UBS para o laboratório (ADR 0037; spec §4), com a temperatura.
class LabShipment < ApplicationRecord
  STATUSES = %w[open sent received].freeze

  belongs_to :origin_unit, class_name: "HealthUnit"
  belongs_to :exam_provider
  belongs_to :created_by_user, class_name: "User"
  belongs_to :sent_by_user, class_name: "User", optional: true
  belongs_to :received_by_user, class_name: "User", optional: true
  has_many :samples, class_name: "LabSample", inverse_of: :lab_shipment
end
