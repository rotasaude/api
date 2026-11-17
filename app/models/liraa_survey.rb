# Levantamento LIRAa (módulo 35a; contrato §1 e §7): draft → drawn → closed
# (trigger). Estratos e quarteirões dos estratos só mudam no rascunho; o
# sorteio grava a versão dos parâmetros. Nunca apagado (trigger).
class LiraaSurvey < ApplicationRecord
  STATUSES = %w[draft drawn closed].freeze

  has_many :strata, class_name: "LiraaStratum", inverse_of: :liraa_survey

  validates :status, inclusion: { in: STATUSES }

  def inspect = "#<LiraaSurvey id=#{id} status=#{status} version=#{version}>"
end
