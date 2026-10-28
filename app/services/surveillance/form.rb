# A ficha de notificação individual do Sinan (módulo 25; contrato §14): os
# campos de config/surveillance/sinan-form.yml (Task 0), carregados uma vez e
# congelados, e a validação da ficha enviada pelo PATCH (Task 11). Tipos,
# domínios e limites vêm só do YAML; este arquivo só os aplica.
#
# validate(hash): cada chave tem de ser da ficha; texto é espaço-colapsado,
# vazio/null vira ausente; telefone, CEP e geocampos perdem a pontuação (só
# dígitos); UF vai para maiúsculas. Valor fora do domínio, do tipo ou do
# limite é RECUSADO, nunca cortado. A recusa leva só o caminho do campo
# (`form.<chave>`), nunca o valor: a ficha é dado de saúde (R18).
module Surveillance
  module Form
    FILE = Rails.root.join("config/surveillance/sinan-form.yml")
    FIELDS = YAML.load_file(FILE).fetch("fields").transform_values { |spec| spec.deep_dup.each_value(&:freeze).freeze }.freeze
    KEYS = FIELDS.keys.freeze
    CBO = /\A\d{6}\z/
    PUNCTUATION = " ().-".freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,47}\z/
    # Marca de "recusado" (nil é "ausente").
    INVALID = Object.new.freeze

    module_function

    def fields = FIELDS
    def keys = KEYS

    # form: o objeto `form` do corpo (chaves texto ou símbolo). ->
    # Result.ok(form: Hash normalizado, só com o que foi preenchido) |
    # fail(:invalid_form, details: { path: "form" | "form.<chave>" }).
    def validate(form)
      return invalid("form") unless form.is_a?(Hash)

      normalized = {}
      form.each do |raw_key, value|
        key = raw_key.to_s
        spec = FIELDS[key]
        # Chave de fora da ficha (ou que nem tem cara de chave): o caminho nunca ecoa texto arbitrário.
        return invalid(key.match?(KEY_FORMAT) ? "form.#{key}" : "form") unless spec

        coerced = coerce(spec, value)
        return invalid("form.#{key}") if coerced.equal?(INVALID)

        if coerced.nil?
          normalized.delete(key)
        else
          normalized[key] = coerced
        end
      end
      Result.ok(form: normalized)
    end

    # Pré-preenchimento (FormPrefill): só os valores que a validação aceita,
    # já normalizados; o que não passa (rua de 70 caracteres) sai, não é cortado.
    def keep_valid(values)
      values.each_with_object({}) do |(key, value), kept|
        result = validate(key => value)
        kept.merge!(result.payload.fetch(:form)) if result.ok?
      end
    end

    # -> String normalizada | nil (ausente) | INVALID.
    def coerce(spec, value)
      return nil if value.nil?
      return INVALID unless value.is_a?(String)

      text = value.squish
      return nil if text.empty?
      return INVALID if text.match?(/[[:cntrl:]]/)

      case spec.fetch("type")
      when "code" then spec.fetch("domain").key?(text) ? text : INVALID
      when "text" then text.length <= spec.fetch("max") ? text : INVALID
      when "digits" then digits(text, spec)
      when "uf" then Professional::UFS.include?(text.upcase) ? text.upcase : INVALID
      when "cbo" then text.match?(CBO) ? text : INVALID
      else raise ArgumentError, "unknown form field type"
      end
    end

    def digits(text, spec)
      number = text.delete(PUNCTUATION)
      return INVALID unless number.match?(/\A\d+\z/)

      size = number.length
      fits = spec.key?("length") ? size == spec["length"] : size.between?(spec.fetch("min", 1), spec.fetch("max"))
      fits ? number : INVALID
    end

    def invalid(path) = Result.fail(:invalid_form, details: { path: path })
    private_class_method :coerce, :digits, :invalid
  end
end
