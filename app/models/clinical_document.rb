# app/models/clinical_document.rb
# Documento clínico (ADR 0033; spec §4): cabeçalho comum dos quatro tipos.
# Imutável (trigger): só issued → cancelled pela autora, com motivo, e a volta
# ao papel do 19b (digital → paper, sem assinatura). Conteúdo do tipo em JSON
# cifrado com a chave da cidade (a forma de saída do contrato §2).
class ClinicalDocument < ApplicationRecord
  KINDS = %w[sick_note attendance_declaration prescription exam_requisition controlled_notification_record].freeze
  PAPER_REASONS = %w[no_certificate signature_unavailable no_sncr_number nurse_antimicrobial feature_disabled free_text_items].freeze
  MODES = %w[digital paper].freeze
  STATUSES = %w[issued cancelled].freeze
  CANCEL_REASON = (10..500)
  # Módulo 31 (P48): a unidade do CAPS sem nome nem modalidade.
  CAPS_UNIT_LABEL = "Centro de Atenção Psicossocial".freeze

  encrypts :content
  encrypts :cancel_reason

  belongs_to :patient, optional: true
  # Módulo 31 (contrato §9, P8): o documento do CAPS nasce da ação, sem
  # atendimento e sem cidadão (CHECKs ck_clinical_documents_parent/_citizen).
  belongs_to :citizen, optional: true
  belongs_to :consultation, optional: true
  belongs_to :attendance, optional: true
  belongs_to :psychosocial_action, optional: true
  belongs_to :author_user, class_name: "User"
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :replaces_document, class_name: "ClinicalDocument", optional: true
  has_many :prescription_items, -> { order(:position) }, dependent: :restrict_with_exception, inverse_of: :clinical_document

  # A unidade do documento: a do atendimento, ou o CAPS da ação (módulo 31) —
  # cabeçalho do impresso, verificação pública e canônico da assinatura.
  def health_unit = attendance ? attendance.health_unit : psychosocial_action&.health_unit
  def psychosocial? = psychosocial_action_id.present?
  # P48: o atestado do CAPS (impresso e canônico assinado) sai com a unidade
  # genérica; a receita e a Notificação, com a identificação completa (farmácia).
  def generic_unit? = psychosocial? && kind == "sick_note"

  # P48: a unidade na verificação pública do documento do CAPS — "Centro de
  # Atenção Psicossocial", o município e o CNES.
  def generic_unit_line
    city = CityProfile.current&.name.presence || Current.city&.name
    [ CAPS_UNIT_LABEL, city, (health_unit&.cnes.presence && "CNES #{health_unit.cnes}") ].compact_blank.join(" — ")
  end
  def content_data = JSON.parse(content)
  def issued? = status == "issued"
  def cancelled? = status == "cancelled"
  def digital? = issue_mode == "digital"
  def prescription? = kind == "prescription"
  def notification_record? = kind == "controlled_notification_record"
  def verification_url = "#{CityPublicUrl.base(Current.city)}/v/#{verification_token}"
  def signature_request = SignatureRequest.find_by(document_type: "ClinicalDocument", document_id: id)
  # A assinatura gravada (pedido signed), ou nil: o impresso e a página pública.
  def signed_signature = SignatureRequest.find_by(document_type: "ClinicalDocument", document_id: id, status: "signed")&.signature
end
