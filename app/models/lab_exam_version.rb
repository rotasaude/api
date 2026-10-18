# Versão imutável do exame do laboratório (trigger): método, material,
# recipiente, código do aparelho e componentes (chave, nome, LOINC, unidade,
# tipo, casas, faixas, limites de digitação, crítico, fórmula). O laudo guarda a versão.
#
# O método mora na coluna `analysis_method` (uma coluna `method` sobrescreveria
# Object#method e quebraria dublês parciais do RSpec, `pp` e bibliotecas). Onde
# o JSON da API (contrato) diz "method", é só o nome da chave, mapeada para cá.
class LabExamVersion < ApplicationRecord
  belongs_to :lab_exam
  belongs_to :created_by_user, class_name: "User"
  belongs_to :lab_instrument, optional: true

  def analyte(key) = analytes.find { |a| a["key"] == key.to_s }
  def entered_analytes = analytes.reject { |a| a["formula"].present? }
  def calculated_analytes = analytes.select { |a| a["formula"].present? }
  def inspect = "#<LabExamVersion id=#{id} lab_exam_id=#{lab_exam_id} version=#{version}>"
end
