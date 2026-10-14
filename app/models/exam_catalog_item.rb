# Exame no catálogo da cidade (ADR 0036): SIGTAP (grupo 02), exige
# autorização, política de liberação ao cidadão, prazos por etapa (dias;
# nil = padrão) e os campos do resultado (chave, rótulo, unidade, LOINC).
class ExamCatalogItem < ApplicationRecord
  POLICIES = %w[immediate after_acknowledgement never_citizen].freeze
  STAGES = %w[authorize schedule collect result acknowledge].freeze

  validates :release_policy, inclusion: { in: POLICIES }
  validates :sigtap_code, format: { with: /\A02\d{8}\z/ }

  def days_for(stage)
    raise ArgumentError, "unknown stage" unless STAGES.include?(stage.to_s)

    public_send(:"#{stage}_days")
  end
  def result_field(key) = result_fields.find { |field| field["key"] == key }
  def result_field_by_loinc(code) = result_fields.find { |field| field["loinc"].present? && field["loinc"] == code }
end
