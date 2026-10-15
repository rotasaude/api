# Token do middleware do laboratório (ADR 0037): só o SHA-256; um ativo por
# laboratório; `simulated` só a semente de dev grava (fake-middleware).
class LabMiddlewareToken < ApplicationRecord
  belongs_to :exam_provider
  belongs_to :created_by_user, class_name: "User", optional: true

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Ativo ou revogado (o revogado responde AR, contrato §7); nil se não existe.
  def self.by_token(token)
    return nil unless token.is_a?(String) && token.length.between?(32, 128)

    find_by(token_digest: digest(token))
  end

  def revoked? = revoked_at.present?
  def inspect = "#<LabMiddlewareToken id=#{id} exam_provider_id=#{exam_provider_id} revoked=#{revoked?}>"
end
