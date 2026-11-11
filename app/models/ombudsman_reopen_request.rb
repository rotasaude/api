# Pedido de reabertura do cidadão (ADR 0051; A12): um pendente por
# manifestação, um por ciclo; decidido uma vez, com quem e quando; o motivo
# nunca muda (trigger). Motivo e decisão cifrados; nunca saem em inspect,
# to_s, pretty_print nem as_json.
class OmbudsmanReopenRequest < ApplicationRecord
  STATES = %w[pending accepted rejected].freeze

  encrypts :reason
  encrypts :decision_text

  belongs_to :ombudsman_manifestation
  belongs_to :decided_by_user, class_name: "User", optional: true

  def inspect = "#<OmbudsmanReopenRequest id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
