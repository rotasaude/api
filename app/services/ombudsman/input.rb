# Regra única dos textos da ouvidoria (Q8; contrato §16): vale String, o
# `strip` vem antes da conta, a conta é em code points (String#length) e o que
# se grava é o valor SEM as bordas. Os intervalos são os de Ombudsman::Catalog
# (BODY, TEXT, EXTRACT, JUSTIFICATION, REOPEN_REASON). Nada aqui entra em log
# nem em mensagem de erro.
module Ombudsman
  module Input
    # Formato de id (uuid) das chaves recebidas; fonte única dos comandos.
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Tamanho máximo do NOME de uma chave recusada no `path` (o nome, nunca o valor).
    KEY_PATH_MAX = 64

    module_function

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # -> String sem as bordas | nil (não é String, ou fora do intervalo).
    def text(value, range)
      return nil unless value.is_a?(String)

      stripped = value.strip
      range.cover?(stripped.length) ? stripped : nil
    end

    def valid_text?(value, range) = !text(value, range).nil?

    # A primeira chave de `attrs` fora de `allowed`, recusada com o NOME
    # (truncado) no path; nil quando todas são conhecidas.
    def unknown_key(attrs, allowed)
      unknown = (attrs.keys.map(&:to_s) - allowed).first
      refuse(unknown[0, KEY_PATH_MAX]) if unknown
    end

    # A recusa de um campo no formato uniforme `{ error, path, problems }`
    # (só o NOME do campo, nunca o valor).
    def refuse(path, error = :invalid_request)
      Result.fail(error, details: { path: path, problems: [ { error: error.to_s, path: path } ] })
    end
  end
end
