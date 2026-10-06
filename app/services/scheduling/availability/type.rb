# Tipo de atendimento como dado puro (ADR 0029 §4.1): o que o cálculo de vagas
# precisa saber. Grupos de CBO são prefixos.
module Scheduling
  module Availability
    Type = Data.define(:key, :duration_minutes, :cbo_prefixes) do
      def serves?(cbo_code) = cbo_prefixes.any? { |prefix| cbo_code.to_s.start_with?(prefix) }
    end
  end
end
