# Livro de idempotência da sincronização (módulo 24b): um `client_uuid` por item
# aceito, só acréscimo (trigger).
class FieldSyncReceipt < ApplicationRecord
  belongs_to :field_device
  belongs_to :user

  validates :item_type, inclusion: { in: FieldSync::Catalog::ITEM_TYPES }

  def inspect = "#<FieldSyncReceipt id=#{id} item_type=#{item_type}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "item_type" => item_type }
end
