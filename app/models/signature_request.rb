# app/models/signature_request.rb
# Pedido de assinatura de um documento (a fila; ADR 0032; spec §4). Um por
# documento; resolvido (signed, returned_to_paper) nunca volta (trigger).
class SignatureRequest < ApplicationRecord
  STATUSES = %w[pending signed failed returned_to_paper].freeze
  REASONS = %w[no_session session_expired provider_unavailable provider_rejected signer_unavailable verification_failed
               certificate_expired certificate_revoked certificate_cpf_mismatch feature_disabled user_request].freeze
  TRANSIENT_REASONS = %w[provider_unavailable signer_unavailable verification_failed].freeze
  MIN_RETURN_NOTE = 10
  MAX_RETURN_NOTE = 500

  encrypts :return_note

  belongs_to :author_user, class_name: "User"
  has_one :signature, dependent: :restrict_with_exception

  scope :pending, -> { where(status: "pending") }

  def pending? = status == "pending"
  def document = Signatures::DocumentTypes.find(document_type, document_id)
end
