# app/services/analytics/suppression.rb
module Analytics
  # Supressão de 1 a 4 SEMPRE no Analytics (D7; spec §6.3; contratos §0),
  # aplicada depois de somar período e recorte. Mesma regra de
  # Admin::SmallCount, que no módulo 11 só valia com filtro.
  module Suppression
    SUPPRESSED = Admin::SmallCount::SUPPRESSED

    module_function

    def cell(count) = Admin::SmallCount.wrap(count.to_i)

    # nil = "sem dado" (denominador 0). Numerador OU denominador em 1..4 →
    # oculto: com os dois à mostra, a taxa devolveria a contagem pequena.
    def rate(numerator, denominator)
      numerator = numerator.to_i
      denominator = denominator.to_i
      return nil if denominator.zero?
      return SUPPRESSED if Admin::SmallCount.small?(numerator) || Admin::SmallCount.small?(denominator)

      (numerator * 100.0 / denominator).round(1)
    end

    # Ordenação sem vazar a ordem das contagens pequenas (contratos §1.1).
    def sort_value(value) = value.is_a?(Numeric) ? value : 0
  end
end
