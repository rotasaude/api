# Par de quarteirões vizinhos (módulo 35a; contrato §1; A-6). Guardado uma vez,
# com city_block_id < neighbor_block_id (CHECK); único entre os vigentes. Pode
# cruzar bairros. Nunca apagado: o par desfeito ganha ended_at (de NULL a
# valor, uma vez; trigger) e pode ser refeito em linha nova.
class CityBlockNeighbor < ApplicationRecord
  belongs_to :city_block
  belongs_to :neighbor_block, class_name: "CityBlock"

  scope :current, -> { where(ended_at: nil) }

  def inspect = "#<CityBlockNeighbor id=#{id} state=#{ended_at.nil? ? 'current' : 'ended'}>"
end
