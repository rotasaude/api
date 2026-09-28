# Supressão de contagem pequena nos painéis filtrados por bairro (ADR 0023;
# spec 2026-09-28 §4.3): contagem por bairro de 1 a 4, somada à urgência, pode
# identificar uma pessoa. Aplicada DEPOIS de agregar. 0 continua 0.
module Admin::SmallCount
  SUPPRESSED = { suppressed: true }.freeze
  RANGE = (1..4)

  module_function

  def small?(value)
    value.is_a?(Numeric) && value == value.to_i && RANGE.cover?(value)
  end

  def wrap(value)
    small?(value) ? SUPPRESSED : value
  end
end
