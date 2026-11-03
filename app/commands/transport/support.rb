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
