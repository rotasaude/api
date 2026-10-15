# Laudo (ADR 0037; RDC 978 art. 167): conteúdo canônico congelado e cifrado
# (lab-report-v1), PDF em exam_files. Só anda para a frente (trigger).
# Assinável pelo 19b: author_user_id = quem liberou; sem consulta.
class LabReport < ApplicationRecord
  STATUSES = %w[pending_signature released rectified withdrawn].freeze

  encrypts :content
  encrypts :rectification_reason
  encrypts :rectification_contacts

  belongs_to :lab_requisition
  belongs_to :exam_provider
  belongs_to :released_by_user, class_name: "User"
  belongs_to :replaces_report, class_name: "LabReport", optional: true
  belongs_to :pdf_file, class_name: "ExamFile", optional: true
  has_many :report_items, class_name: "LabReportItem", inverse_of: :lab_report
  has_many :items, through: :report_items, source: :lab_requisition_item

  def author_user_id = released_by_user_id
  def consultation_id = nil
  def content_data = JSON.parse(content)
  def verification_url = "#{CityPublicUrl.base(Current.city)}/v/#{verification_token}"
  def signature_request = SignatureRequest.find_by(document_type: "LabReport", document_id: id)
  def inspect = "#<LabReport id=#{id} version=#{version} status=#{status} signature_kind=#{signature_kind}>"
end
