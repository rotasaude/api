# Dicionários das fichas de cadastro do LEDI 8.7.0 (módulo 24a, ADR 0042;
# contrato §15): config/ledi/registration_dictionaries.yml, produzido pela
# prova técnica (Task 0). Aqui só tipo, domínio e limites de cada campo; as
# regras condicionais (entre campos, por recusa, por tipo de imóvel) moram no
# TerritoryRegistry::Rules, uma linha por regra. Recusas só com o caminho do
# campo — nunca o valor (o corpo tem dado de saúde).
module TerritoryRegistry
  module Dictionary
    FILE = Rails.root.join("config/ledi/registration_dictionaries.yml")
    DATA = YAML.load_file(FILE).freeze
    SECTIONS = DATA.fetch("sections").freeze
    DOMAINS = DATA.fetch("domains").freeze
    STRING_DOMAINS = DATA.fetch("string_domains").freeze
    TEXT_MAX = 100
    # Recusa padrão por seção (contrato §4 e §5): a moradia é do domicílio.
    REASONS = { "living_conditions" => :invalid_household }.freeze
    DEFAULT_REASON = :invalid_registration

    # "Validar nome" (vendor/ledi/8.7.0/docs/validar_nome.html, regras do
    # CADSUS): letras romanas (com K, W, Y), acentos agudo, circunflexo, til e
    # trema, e apóstrofo (reto ou tipográfico). A cedilha não está na lista
    # oficial, mas é de nome brasileiro comum (GONÇALVES) e o PEC a aceita.
    NAME_MIN = 3
    NAME_MAX = 70
    NAME_MARKS = "̧́̂̃̈".freeze
    NAME_TERM = /\A(?:[A-Za-z'’][#{NAME_MARKS}]*)+\z/

    module_function

    def section(name) = SECTIONS.fetch(name.to_s)
    def domain(name) = DOMAINS.fetch(name.to_s)
    def string_domain(name) = STRING_DOMAINS.fetch(name.to_s)

    # Regras 1, 2, 3, 5, 6 e 7 do "Validar nome"; a 4 (maiúsculas) é
    # normalização, feita por quem monta a ficha. Quem chama faz squish antes:
    # espaço nas pontas ou duplicado é recusado aqui.
    def valid_name?(value, max: NAME_MAX)
      return false unless value.is_a?(String) && value.length.between?(NAME_MIN, max)

      terms = value.split(/ /, -1) # regex: split(" ") juntaria espaços duplicados
      return false if terms.size < 2 || terms.any?(&:empty?)
      return false unless terms.all? { |term| term.unicode_normalize(:nfd).match?(NAME_TERM) }
      return false if term_size(terms[0]) == 1 && term_size(terms[1]) == 1
      return false if terms.size == 2 && terms.all? { |term| term_size(term) == 2 }

      true
    end

    def term_size(term) = term.unicode_normalize(:nfc).length
    private_class_method :term_size

    # section: nome de seção do YAML ou um Hash de campos (o `fields` de um
    # object). raw nil → values nil (seção ausente; o Rules decide se pode).
    # Valor nil, texto em branco e lista vazia contam como ausentes. O
    # `required` de primeiro nível depende de condição (recusa, tipo de imóvel)
    # e é aplicado pelo Rules; dentro de um object vale sempre que ele vem.
    def parse(section, raw, prefix:, reason: nil)
      fields = section.is_a?(Hash) ? section : self.section(section)
      reason ||= section.is_a?(Hash) ? DEFAULT_REASON : REASONS.fetch(section.to_s, DEFAULT_REASON)
      walk(fields, raw, prefix, reason, nested: false)
    end

    def walk(fields, raw, prefix, reason, nested:)
      return Result.ok(values: nil) if raw.nil?
      return refuse(reason, prefix) unless raw.is_a?(Hash)

      values = {}
      raw.each do |key, value|
        key = key.to_s
        spec = fields[key]
        return refuse(reason, "#{prefix}.#{key}") unless spec

        converted = convert(spec, value, "#{prefix}.#{key}", reason)
        return converted if converted.is_a?(Result)

        values[key] = converted unless converted.nil?
      end
      if nested
        missing = fields.find { |key, spec| spec["required"] && !values.key?(key) }
        return refuse(reason, "#{prefix}.#{missing.first}") if missing
      end
      Result.ok(values: values)
    end
    private_class_method :walk

    # Valor convertido, nil (ausente) ou a recusa (Result).
    def convert(spec, value, path, reason)
      return nil if value.nil?

      case spec.fetch("type")
      when "bool" then [ true, false ].include?(value) ? value : refuse(reason, path)
      when "code" then code?(spec, value) ? value : refuse(reason, path)
      when "codes" then codes(spec, value, path, reason)
      when "text" then text(spec, value, path, reason)
      when "name" then name_value(spec, value, path, reason)
      when "digits" then digits?(spec, value) ? value : refuse(reason, path)
      when "date" then iso_date(value) || refuse(reason, path)
      when "date_month" then month(value) || refuse(reason, path)
      when "count" then value.is_a?(Integer) && value.positive? ? value : refuse(reason, path)
      when "object"
        parsed = walk(spec.fetch("fields"), value, path, reason, nested: true)
        parsed.failure? ? parsed : parsed.payload[:values].presence
      else raise ArgumentError, "tipo de campo desconhecido no dicionário: #{spec['type']}"
      end
    end
    private_class_method :convert

    def code?(spec, value) = value.is_a?(Integer) && domain(spec.fetch("domain")).key?(value)
    private_class_method :code?

    def codes(spec, value, path, reason)
      return refuse(reason, path) unless value.is_a?(Array)
      return nil if value.empty?
      return refuse(reason, path) if value.uniq.size != value.size
      return refuse(reason, path) if spec["max_items"] && value.size > spec["max_items"]
      return refuse(reason, path) unless value.all? { |item| code?(spec, item) }

      value
    end
    private_class_method :codes

    def text(spec, value, path, reason)
      return refuse(reason, path) unless value.is_a?(String)

      text = value.strip.presence
      return nil unless text
      return Result.fail(:too_long, details: { path: path }) if text.length > spec.fetch("max", TEXT_MAX)
      return refuse(reason, path) if spec["min"] && text.length < spec["min"]

      text
    end
    private_class_method :text

    def name_value(spec, value, path, reason)
      return refuse(reason, path) unless value.is_a?(String)

      name = value.squish.presence
      return nil unless name
      return Result.fail(:too_long, details: { path: path }) if name.length > spec.fetch("max", NAME_MAX)
      return refuse(reason, path) unless valid_name?(name, max: spec.fetch("max", NAME_MAX))

      name
    end
    private_class_method :name_value

    def digits?(spec, value)
      value.is_a?(String) && value.match?(/\A\d+\z/) &&
        value.length >= spec.fetch("min", 1) && (spec["max"].nil? || value.length <= spec["max"])
    end
    private_class_method :digits?

    # "AAAA-MM-DD" canônico, ou nil.
    def iso_date(value)
      return value.iso8601 if value.is_a?(Date)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value).iso8601
    rescue Date::Error
      nil
    end

    # "AAAA-MM" canônico, ou nil.
    def month(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)

      value
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :refuse
  end
end
