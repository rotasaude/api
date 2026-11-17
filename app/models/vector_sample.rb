# Amostra de larvas da inspeção (módulo 35a; contrato §1 e §9): etiqueta única,
# número sequencial na inspeção. O resultado entra todo de uma vez (CHECK) e
# só muda com nota nova de correção (trigger); a nota é cifrada com a chave da
# cidade. Sem dado em inspect/to_s/as_json além de id e etiqueta.
class VectorSample < ApplicationRecord
  encrypts :result_note

  belongs_to :vector_inspection, inverse_of: :samples
  belongs_to :result_by_user, class_name: "User", optional: true

  scope :pending_results, -> { where(result_at: nil) }

  def inspect = "#<VectorSample id=#{id} label=#{label}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "label" => label }
end
