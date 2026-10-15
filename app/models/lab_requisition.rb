# Requisição do laboratório (ADR 0037; spec §4–§5): junta exames do 21a do
# paciente. Nome da mãe, informação clínica e quem retirou, cifrados.
class LabRequisition < ApplicationRecord
  STATUSES = %w[open in_analysis typed released delivered].freeze
  PLACES = %w[ubs lab].freeze
  SEXES = %w[male female].freeze

  encrypts :mother_name
  encrypts :clinical_info
  encrypts :delivered_to

  belongs_to :patient
  belongs_to :exam_provider
  belongs_to :origin_unit, class_name: "HealthUnit"
  belongs_to :opened_by_user, class_name: "User"
  belongs_to :delivered_by_user, class_name: "User", optional: true
  has_many :items, -> { order(:created_at, :id) }, class_name: "LabRequisitionItem", inverse_of: :lab_requisition
  has_many :samples, -> { order(:barcode) }, class_name: "LabSample", inverse_of: :lab_requisition
  has_many :reports, -> { order(:version) }, class_name: "LabReport", inverse_of: :lab_requisition

  def self.next_number = format("%08d", connection.select_value("SELECT nextval('lab_requisition_number_seq')"))

  def inspect = "#<LabRequisition id=#{id} number=#{number} status=#{status}>"
end
