# Abertura da identidade preservada ou de um anexo protegido (ADR 0051): quem,
# quando e por quê. Só acréscimo (trigger; a re-cifra regrava a
# justificativa). Justificativa cifrada; nunca sai em inspect, to_s,
# pretty_print nem as_json.
class OmbudsmanIdentityAccess < ApplicationRecord
  SCOPES = %w[identity attachment].freeze

  encrypts :justification

  belongs_to :ombudsman_manifestation
  belongs_to :user
  belongs_to :exam_file, optional: true

  def inspect = "#<OmbudsmanIdentityAccess id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
