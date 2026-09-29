# Título e texto da campanha (spec 2026-09-29 §3.1): pontas aparadas, título
# 3–120, texto 10–2000, texto simples (sem tag HTML: `<` seguido de letra, `/`
# ou `!`; "idade < 60" e "idade < a" passam).
module Campaigns
  module ContentValidation
    HTML = %r{<[a-zA-Z/!]}
    LIMITS = { "title" => Campaign::TITLE_LENGTH, "body" => Campaign::BODY_LENGTH }.freeze

    module_function

    def errors(attrs, required: false)
      LIMITS.flat_map do |key, range|
        next(required ? [ error(key, "required") ] : []) unless attrs.key?(key)

        value = attrs[key]
        next [ error(key, "not_a_string") ] unless value.is_a?(String)
        next [ error(key, "length") ] unless range.cover?(value.strip.length)
        next [ error(key, "html_not_allowed") ] if value.match?(HTML)

        []
      end
    end

    def error(key, message)
      { path: "/#{key}", message: message }
    end
  end
end
