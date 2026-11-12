# Regra única dos textos da ouvidoria (Q8; contrato §16): vale String, o
# `strip` vem antes da conta, a conta é em code points (String#length) e o que
# se grava é o valor SEM as bordas. Os intervalos são os de Ombudsman::Catalog
# (BODY, TEXT, EXTRACT, JUSTIFICATION, REOPEN_REASON). Nada aqui entra em log
# nem em mensagem de erro.
module Ombudsman
  module Input
    module_function

    # -> String sem as bordas | nil (não é String, ou fora do intervalo).
    def text(value, range)
      return nil unless value.is_a?(String)

      stripped = value.strip
      range.cover?(stripped.length) ? stripped : nil
    end

    def valid_text?(value, range) = !text(value, range).nil?

    # A recusa de um campo no formato uniforme `{ error, path, problems }`
    # (só o NOME do campo, nunca o valor).
    def refuse(path, error = :invalid_request)
      Result.fail(error, details: { path: path, problems: [ { error: error.to_s, path: path } ] })
    end
  end
end
