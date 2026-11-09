# Tempo máximo de espera de cada cor (ADR 0050; Desvio 9): os `levels` do
# protocolo dado, ou o padrão 0/10/60/120/240 sem protocolo. Cada
# classificação grava o tempo da sua cor no momento — este é o snapshot.
# Sempre as 5 cores, na ordem de Catalog::COLORS.
module Urgency
  module Levels
    module_function

    def for(protocol)
      return Catalog::DEFAULT_MAX_WAIT if protocol.nil?

      levels = Array(protocol.definition&.dig("levels")).each_with_object({}) do |level, acc|
        next unless level.is_a?(Hash) && Catalog::COLORS.include?(level["color"]) && level["max_wait_minutes"].is_a?(Integer)

        acc[level["color"]] = level["max_wait_minutes"]
      end
      Catalog::DEFAULT_MAX_WAIT.merge(levels)
    end
  end
end
