# Produto da vigilância ambiental (módulo 35a, ADR 0054; contrato §4): código
# único sem caixa, unidade (g, ml, un), tamanho da carga e os usos (focal,
# perifocal, espacial). Unidade e carga ficam fixas depois do primeiro lote ou
# medida (trigger; o comando responde 409 product_in_use); nome, usos e ativo
# mudam a qualquer tempo. Nunca apagado (trigger). version sobe a cada escrita.
class VectorProduct < ApplicationRecord
  has_many :stock_lots, inverse_of: :vector_product
  has_many :measures, class_name: "VectorInspectionMeasure", inverse_of: :vector_product

  scope :active_products, -> { where(active: true) }

  def inspect = "#<VectorProduct id=#{id} code=#{code} version=#{version}>"
end
