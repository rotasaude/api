# Código de barras de um nível do lote (Desvio 1): único na cidade; nunca só 10 dígitos (espaço das amostras).
class LabQcLotBarcode < ApplicationRecord
  FORMAT = /\A[A-Za-z0-9._-]{3,30}\z/
  SAMPLE_SPACE = /\A[0-9]{10}\z/

  belongs_to :lab_qc_lot

  # C-E13: o código é único e procurado sem diferenciar caixa; guardado como digitado.
  def self.find_ci(code) = code.is_a?(String) ? find_by("lower(barcode) = ?", code.downcase) : nil
  def self.valid_code?(code) = code.is_a?(String) && code.match?(FORMAT) && !code.match?(SAMPLE_SPACE)
end
