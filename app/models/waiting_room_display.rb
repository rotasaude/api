# TV da sala de espera (ADR 0050; contrato §8 e §14 Q8; Valor fixado 6):
# código de pareamento e token guardados só como SHA-256; o token vale até a
# TV ser revogada. Revogar (ou parear de novo com token vivo) move o digest
# vivo para `revoked_token_digest`: a TV antiga recebe display_revoked e
# pede um novo código. Só o último anterior fica — um token mais antigo
# responde invalid_token. Nunca apagada (trigger). Os digests nunca saem no
# inspect nem no as_json.
class WaitingRoomDisplay < ApplicationRecord
  PUBLIC_ATTRIBUTES = %w[id health_unit_id name active show_wait_times paired_at last_seen_at revoked_at].freeze

  belongs_to :health_unit
  belongs_to :created_by_user, class_name: "User"

  scope :paired_active, -> { where(active: true, revoked_at: nil).where.not(token_digest: nil) }

  def self.digest(value) = Digest::SHA256.hexdigest(value.to_s)

  # A TV do token, vivo ou o último revogado (o painel confere com
  # #live_token?: o revogado responde display_revoked); nil se nenhum casa.
  def self.by_token(token)
    return nil unless token.is_a?(String) && token.length.between?(32, 128)

    value = digest(token)
    find_by(token_digest: value) || find_by(revoked_token_digest: value)
  end

  def revoked? = revoked_at.present?
  # Token vivo: pareada e não revogada (a lista mostra `paired`).
  def paired? = token_digest.present? && !revoked?
  # O token dado é o vivo desta TV ativa (o revogado e o de TV desativada não).
  def live_token?(token) = active && paired? && token_digest == self.class.digest(token)

  def inspect = "#<WaitingRoomDisplay id=#{id} health_unit_id=#{health_unit_id} revoked=#{revoked?}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = attributes.slice(*PUBLIC_ATTRIBUTES)
end
