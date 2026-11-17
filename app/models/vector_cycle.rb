# Ciclo de trabalho do ano (módulo 35a; contrato §1): número 1–12, único por
# ano, sem datas sobrepostas entre ciclos (exclusion GiST, intervalo fechado).
# Nunca apagado (trigger).
class VectorCycle < ApplicationRecord
  validates :number, inclusion: { in: VectorControl::Catalog::CYCLE_NUMBERS }

  def inspect = "#<VectorCycle id=#{id} year=#{year} number=#{number}>"
end
