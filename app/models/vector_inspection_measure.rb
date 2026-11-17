# Medida de controle na inspeção (módulo 35a; contrato §1, §3 e §4): a
# mecânica sem produto, cargas nem quantidade; as químicas com o produto, as
# cargas e a quantidade (cargas × carga do produto na hora, A-2). Uma por
# (inspeção, método, produto), nulo como valor. Só acréscimo (trigger). É o
# documento do movimento de estoque da baixa e do estorno (A-1).
class VectorInspectionMeasure < ApplicationRecord
  belongs_to :vector_inspection, inverse_of: :measures
  belongs_to :vector_product, optional: true, inverse_of: :measures
  has_many :movements, class_name: "StockMovement", inverse_of: :vector_inspection_measure
  has_one :shortfall, class_name: "VectorStockShortfall", inverse_of: :vector_inspection_measure

  # A coluna se chama `method` (contrato §1): sem argumento é o atributo; com
  # argumento continua sendo Object#method (o leitor gerado não aceita argumento).
  OBJECT_METHOD = Object.instance_method(:method)
  def method(*args, &) = args.empty? ? self[:method] : OBJECT_METHOD.bind_call(self, *args, &)

  def inspect = "#<VectorInspectionMeasure id=#{id} method=#{self[:method]}>"
end
