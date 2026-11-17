# Quarteirão do bairro (módulo 35a, ADR 0054; contrato §1). Número único sem
# caixa no bairro (idx_city_blocks_number). Nunca apagado: desativa (trigger).
# version sobe a cada escrita (feed do app).
class CityBlock < ApplicationRecord
  belongs_to :neighborhood
  belongs_to :created_by_user, class_name: "User"

  validates :number, format: { with: VectorControl::Catalog::BLOCK_NUMBER }

  scope :active_blocks, -> { where(active: true) }

  # Ordem natural do número (a mesma do sorteio do LIRAa): os dígitos iniciais
  # como inteiro, depois o resto sem caixa. Número sem dígitos iniciais vem depois dos
  # numéricos; o empate cai em lower(number) e, por fim, em number.
  scope :natural_number_order, lambda {
    order(Arel.sql("(substring(city_blocks.number from '^[0-9]+'))::numeric NULLS LAST"),
          Arel.sql("lower(city_blocks.number)"), :number)
  }

  def inspect = "#<CityBlock id=#{id} neighborhood_id=#{neighborhood_id} number=#{number} version=#{version}>"
end
