# Instrumento da ação do CAPS (ADR 0049; plano, Desvio 3; contrato P3), sobre
# os `instrument_code` da SIGTAP da competência do mês da ação: `09` com
# participante matriculado → RAAS-PSI; senão `02` → BPA-I; senão `01` → BPA-C.
# `09` sem matriculado (e sem 02/01) → :enrollment_required; nenhum dos três →
# :instrument_mismatch. Gravado na ação; a ação nunca muda de instrumento.
module Psychosocial
  module Instrument
    module_function

    # codes: os instrument_code do procedimento. -> String | :enrollment_required | :instrument_mismatch
    def for(codes, enrolled:)
      codes = Array(codes)
      return "raas_psi" if enrolled && codes.include?("09")
      return "bpa_i" if codes.include?("02")
      return "bpa_c" if codes.include?("01")
      return :enrollment_required if codes.include?("09")

      :instrument_mismatch
    end
  end
end
