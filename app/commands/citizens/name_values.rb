# Nome conferido no documento (ADR 0031; contratos §2 e §9): com a chave,
# completo 3–200 obrigatório; social e da mãe opcionais, até 200. Espaços
# normalizados; texto vazio = não informado. Sem a chave (ABSENT; cliente
# antigo durante o deploy), nada a gravar — a consulta pede o nome depois.
module Citizens
  module NameValues
    FIELDS = %w[full_name social_name mother_name].freeze
    ABSENT = Object.new.freeze

    module_function

    def call(full_name:, social_name: nil, mother_name: nil)
      return Result.ok({}) if full_name.equal?(ABSENT)

      raw = { "full_name" => full_name, "social_name" => social_name, "mother_name" => mother_name }
      values = {}
      FIELDS.each do |field|
        value = raw[field]
        return invalid(field) unless value.nil? || value.is_a?(String)

        text = value.to_s.squish
        if field == "full_name"
          return invalid(field) unless Citizen::NAME_LIMITS[field].cover?(text.length)
        elsif text.length > Citizen::NAME_LIMITS[field].max
          return invalid(field)
        end
        values[field.to_sym] = text.presence
      end
      Result.ok(values)
    end

    def invalid(field) = Result.fail(:"invalid_#{field}")
    private_class_method :invalid
  end
end
