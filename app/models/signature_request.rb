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
  # laudo — nunca consulta, adendo ou documento clínico.
  def self.signable_by(user)
    mine = where(author_user_id: user.id)
    lab_only = !CitizenVerificationPolicy.new(user, nil).care? && user.has_role?("lab_releaser")
    lab_only ? mine.where(document_type: "LabReport") : mine
  end

  def pending? = status == "pending"
  def document = Signatures::DocumentTypes.find(document_type, document_id)
end
