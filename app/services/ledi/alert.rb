# Nível de alerta da competência (spec §6.5; contratos §4.3 e §8). Puro: o painel
# da cidade e o console usam a mesma regra. `sending` não conta como atenção
# (R18): é entrega em curso, não pendência.
module Ledi
  module Alert
    ATTENTION_DAYS = 5
    CRITICAL_DAYS = 3

    module_function

    def level(counts:, business_days_left:, record_mode:)
      return "none" if business_days_left <= 0
      return "critical" if record_mode == "record" && counts[:accepted].zero? && business_days_left <= CRITICAL_DAYS

      open = counts.values_at(:pending, :rejected, :failed).sum
      open.positive? && business_days_left <= ATTENTION_DAYS ? "attention" : "none"
    end
  end
end
