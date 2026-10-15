# Componente do exame do catálogo-base: chave, LOINC, unidade, tipo, faixas de partida.
class LabAnalyteTemplate < PlatformRecord
  VALUE_TYPES = %w[numeric text choice].freeze
  KEY = /\A[a-z][a-z0-9_]{0,39}\z/
  LOINC = /\A\d{1,7}-\d\z/

  belongs_to :lab_exam_template
end
