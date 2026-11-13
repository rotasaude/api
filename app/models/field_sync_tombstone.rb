# Lápide de remoção do download (módulo 24b): domicílio ou cadastro que saiu da
# microárea. Só acréscimo (trigger).
class FieldSyncTombstone < ApplicationRecord
  belongs_to :micro_area

  validates :entity_type, inclusion: { in: FieldSync::Catalog::TOMBSTONE_ENTITY_TYPES }
  validates :reason, inclusion: { in: FieldSync::Catalog::TOMBSTONE_REASONS }

  def inspect = "#<FieldSyncTombstone id=#{id} entity_type=#{entity_type} reason=#{reason}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "entity_type" => entity_type, "reason" => reason }
end
