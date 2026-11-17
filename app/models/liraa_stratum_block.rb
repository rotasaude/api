# Quarteirão do estrato do LIRAa (módulo 35a; contrato §1 e §7; A-7): o
# levantamento é cópia do estrato (trigger) e o quarteirão aparece uma vez por
# levantamento (idx_liraa_stratum_blocks_block). Sorteado ⇔ início no
# quarteirão (1–5; Q16: sempre o 1º imóvel). Fixo fora do rascunho (trigger);
# apagado só no rascunho.
class LiraaStratumBlock < ApplicationRecord
  belongs_to :liraa_stratum, inverse_of: :stratum_blocks
  belongs_to :liraa_survey
  belongs_to :city_block

  def inspect = "#<LiraaStratumBlock id=#{id} liraa_stratum_id=#{liraa_stratum_id} city_block_id=#{city_block_id} drawn=#{drawn}>"
end
