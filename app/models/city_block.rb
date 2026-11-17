# Quarteirão do bairro (módulo 35a, ADR 0054; contrato §1). Número único sem
# caixa no bairro (idx_city_blocks_number). Nunca apagado: desativa (trigger).
# version sobe a cada escrita (feed do app).
class CityBlock < ApplicationRecord
  belongs_to :neighborhood
  belongs_to :created_by_user, class_name: "User"

  validates :number, format: { with: VectorControl::Catalog::BLOCK_NUMBER }

  scope :active_blocks, -> { where(active: true) }

  def inspect = "#<CityBlock id=#{id} neighborhood_id=#{neighborhood_id} number=#{number} version=#{version}>"
end
