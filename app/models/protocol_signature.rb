# Uma assinatura de revisor sobre um conteúdo exato, para uma finalidade
# (spec de assinaturas §5). Se conta ou não para um ato é pergunta de
# Protocols::Signatures, feita no momento do ato. Só aceita acréscimo.
class ProtocolSignature < ApplicationRecord
  PURPOSES = %w[publication activation].freeze

  belongs_to :protocol_definition
  belongs_to :signer, class_name: "User", foreign_key: :signer_user_id, inverse_of: false

  validates :content_digest, presence: true
  validates :purpose, inclusion: { in: PURPOSES }

  def readonly? = persisted?
end
