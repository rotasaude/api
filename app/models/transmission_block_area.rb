# Quarteirão da área do bloqueio (módulo 35a; contrato §1 e §8): único pelo
# par. Só acréscimo (trigger).
class TransmissionBlockArea < ApplicationRecord
  belongs_to :transmission_block, inverse_of: :areas
  belongs_to :city_block

  def inspect = "#<TransmissionBlockArea id=#{id} transmission_block_id=#{transmission_block_id} city_block_id=#{city_block_id}>"
end
