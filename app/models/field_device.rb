# Aparelho de campo (módulo 24b, ADR 0052). O token (`rsf_…`) nunca é guardado:
# só o SHA-256, no padrão do LabMiddlewareToken. Só `last_used_at` e a revogação
# (uma vez; trigger) mudam. Sem token, digest nem nome em inspect/to_s/as_json.
class FieldDevice < ApplicationRecord
  belongs_to :user
  belongs_to :professional
  belongs_to :revoked_by_user, class_name: "User", optional: true

  validates :name, presence: true, length: { maximum: FieldSync::Catalog::DEVICE_NAME.last }
  validates :revoked_reason, inclusion: { in: FieldSync::Catalog::REVOKED_REASONS }, allow_nil: true

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Ativo ou revogado (o revogado responde 401 device_revoked); nil se não existe
  # ou se o texto não tem a forma de um token.
  def self.by_token(token)
    return nil unless token.is_a?(String) && token.start_with?(FieldSync::Catalog::TOKEN_PREFIX) && token.length.between?(40, 60)

    find_by(token_digest: digest(token))
  end

  def revoked? = revoked_at.present?
  def state = revoked? ? "revoked" : "active"

  def inspect = "#<FieldDevice id=#{id} state=#{state}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
