# last_error nunca guarda dado de cidadão: sequências de 11 ou mais dígitos
# (CPF, CNS, telefone) viram [número], espaços normalizados, até 500.
# CNES (7) e INE (10) continuam legíveis — são da unidade e da equipe.
module Ledi
  module ErrorText
    MAX = 500

    module_function

    def sanitize(text)
      text.to_s.gsub(/\d{11,}/, "[número]").squish.truncate(MAX, omission: "")
    end
  end
end
