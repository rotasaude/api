# Estrato do LIRAa (módulo 35a; contrato §1 e §7): modo, N, n, intervalo e
# início casual dos quarteirões, gravados no sorteio. Fixo fora do rascunho do
# levantamento (trigger); apagado só no rascunho, depois dos quarteirões dele.
class LiraaStratum < ApplicationRecord
  self.table_name = "liraa_strata"

  belongs_to :liraa_survey, inverse_of: :strata
  has_many :stratum_blocks, class_name: "LiraaStratumBlock", inverse_of: :liraa_stratum
  has_many :draw_items, class_name: "LiraaDrawItem", inverse_of: :liraa_stratum

  validates :mode, inclusion: { in: VectorControl::Catalog::LIRAA_MODES }

  def inspect = "#<LiraaStratum id=#{id} liraa_survey_id=#{liraa_survey_id} mode=#{mode}>"
end
