# app/models/clinical_document.rb
# Documento clínico (ADR 0033; spec §4): cabeçalho comum dos quatro tipos.
# Imutável (trigger): só issued → cancelled pela autora, com motivo, e a volta
# ao papel do 19b (digital → paper, sem assinatura). Conteúdo do tipo em JSON
# cifrado com a chave da cidade (a forma de saída do contrato §2).
class ClinicalDocument < ApplicationRecord
  KINDS = %w[sick_note attendance_declaration prescription exam_requisition].freeze
  MODES = %w[digital paper].freeze
  STATUSES = %w[issued cancelled].freeze
  CANCEL_REASON = (10..500)

  encrypts :content
  encrypts :cancel_reason

  belongs_to :patient, optional: true
  belongs_to :citizen
  belongs_to :consultation, optional: true
  belongs_to :attendance
  belongs_to :author_user, class_name: "User"
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :replaces_document, class_name: "ClinicalDocument", optional: true
  has_many :prescription_items, -> { order(:position) }, dependent: :restrict_with_exception, inverse_of: :clinical_document

  def content_data = JSON.parse(content)
  def issued? = status == "issued"
  def cancelled? = status == "cancelled"
  def digital? = issue_mode == "digital"
  def prescription? = kind == "prescription"
  def verification_url = "#{CityPublicUrl.base(Current.city)}/v/#{verification_token}"
  def signature_request = SignatureRequest.find_by(document_type: "ClinicalDocument", document_id: id)
  # A assinatura gravada (pedido signed), ou nil: o impresso e a página pública.
  def signed_signature = SignatureRequest.find_by(document_type: "ClinicalDocument", document_id: id, status: "signed")&.signature
end
