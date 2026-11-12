# Atribuição de microárea a um CBO de campo que não é o ACS responsável (módulo
# 24b, ADR 0052, 6A). Nunca apagada; só encerra, uma vez (trigger). Reatribuir
# cria linha nova (único ativo por microárea e profissional).
class MicroAreaFieldAssignment < ApplicationRecord
  belongs_to :micro_area
  belongs_to :professional
  belongs_to :assigned_by_user, class_name: "User"
  belongs_to :ended_by_user, class_name: "User", optional: true

  scope :active, -> { where(ended_at: nil) }

  def active? = ended_at.nil?

  def inspect = "#<MicroAreaFieldAssignment id=#{id} state=#{active? ? 'active' : 'ended'}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
end
