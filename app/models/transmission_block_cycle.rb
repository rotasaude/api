# Ciclo de aplicação do bloqueio (módulo 35a; contrato §1 e §8): número 1–3,
# único no bloqueio. Nunca apagado (trigger).
class TransmissionBlockCycle < ApplicationRecord
  belongs_to :transmission_block, inverse_of: :cycles

  def inspect = "#<TransmissionBlockCycle id=#{id} transmission_block_id=#{transmission_block_id} number=#{number}>"
end
