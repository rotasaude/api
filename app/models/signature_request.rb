# app/models/signature_request.rb
# Pedido de assinatura de um documento (a fila; ADR 0032; spec §4). Um por
# documento; resolvido (signed, returned_to_paper) nunca volta (trigger).
class SignatureRequest < ApplicationRecord
  STATUSES = %w[pending signed failed returned_to_paper].freeze
  REASONS = %w[no_session session_expired provider_unavailable provider_rejected signer_unavailable verification_failed
               certificate_expired certificate_revoked certificate_cpf_mismatch feature_disabled user_request
               document_cancelled].freeze
  TRANSIENT_REASONS = %w[provider_unavailable signer_unavailable verification_failed].freeze
  MIN_RETURN_NOTE = 10
  MAX_RETURN_NOTE = 500

  encrypts :return_note

  belongs_to :author_user, class_name: "User"
  has_one :signature, dependent: :restrict_with_exception

  scope :pending, -> { where(status: "pending") }

  # Os pedidos que o usuário alcança no 19b: os dele. Quem não é profissional
  # (care?) e entra só como liberador do laboratório (ADR 0037) alcança só
  # laudo; só com o papel do CAPS (módulo 31, P28), só o documento clínico da
  # ação do CAPS; com os dois, a união — nunca consulta ou adendo.
  def self.signable_by(user)
    mine = where(author_user_id: user.id)
    return mine if CitizenVerificationPolicy.new(user, nil).care?

    scopes = []
    scopes << mine.where(document_type: "LabReport") if user.has_role?("lab_releaser")
    if Psychosocial::Access.staff?(user)
      scopes << mine.where(document_type: "ClinicalDocument",
                           document_id: ClinicalDocument.where.not(psychosocial_action_id: nil).select(:id))
    end
    scopes.empty? ? mine : scopes.reduce(:or)
  end

  def pending? = status == "pending"
  def document = Signatures::DocumentTypes.find(document_type, document_id)
end
