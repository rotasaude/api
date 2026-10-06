# last_error nunca guarda dado de cidadão: sequências de 11 ou mais dígitos
# (CPF, CNS, telefone, cartão, CNPJ), mesmo separadas por . - / ou um espaço,
# viram [número]; espaços normalizados, até 500.
# CNES (7), INE (10) e datas continuam legíveis — são da unidade e da equipe.
module Ledi
  module ErrorText
    MAX = 500
    DIGIT_RUN = %r{\d(?:[.\-/ ]?\d){10,}}

    module_function

    def sanitize(text)
      text.to_s.gsub(DIGIT_RUN, "[número]").squish.truncate(MAX, omission: "")
    end
  end
end
