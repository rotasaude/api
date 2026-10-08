# app/services/consultations/cbos.rb
# Quem registra consulta (ADR 0031; spec §4; Desvio 2): CBO de nível superior
# que o layout aceita no Atendimento Individual (tabela do MIAI, módulo 18) e
# fora da odontologia (2232, módulo 28).
module Consultations
  module Cbos
    EXCLUDED_PREFIXES = %w[2232].freeze

    module_function

    def allowed?(cbo)
      cbo = cbo.to_s
      Ledi::ScreeningMapping.miai_cbo?(cbo) && EXCLUDED_PREFIXES.none? { |prefix| cbo.start_with?(prefix) }
    end
  end
end
