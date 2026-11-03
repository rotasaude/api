# Peças comuns dos comandos de cadastro da frota (ADR 0048): recusa de campo
# com `problems` (todas de uma vez) e leitura estrita de tipos do corpo JSON.
module Transport
  module Support
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.fail(:invalid_request, path: <primeiro>, problems: [ {path, error} ])
    def refuse(paths)
      problems = Array(paths).map { |path| { path: path, error: "invalid_request" } }
      Result.fail(:invalid_request, details: { path: problems.first[:path], problems: problems })
    end

    # Recusa de uma regra com nome próprio (user_not_driver…), no formato uniforme.
    def refuse_with(error, path)
      Result.fail(error, details: { path: path, problems: [ { path: path, error: error.to_s } ] })
    end

    # Várias recusas de nome próprio de uma vez ([ { path:, error: } ]): a
    # primeira vai para o topo.
    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    # Chaves fora da lista (C10, como no TFD): os NOMES, truncados, com o
    # prefixo do objeto aninhado ("companion.x", "stops.0.x").
    KEY_PATH_MAX = 64

    def unknown_keys(hash, keys, prefix = nil)
      return [] unless hash.is_a?(Hash)

      (hash.keys.map(&:to_s) - keys).map { |key| [ prefix, key[0, KEY_PATH_MAX] ].compact.join(".") }
    end

    def text(value, range)
      return nil unless value.is_a?(String)

      text = value.strip
      range.cover?(text.length) ? text : nil
    end

    def integer(value, range) = value.is_a?(Integer) && range.cover?(value) ? value : nil
    def boolean?(value) = [ true, false ].include?(value)

    # "YYYY-MM-DD" real; senão nil.
    def date(value)
      return nil unless value.is_a?(String) && value.match?(ISO_DATE)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end
  end
end
