# Listas fechadas da RAAS do CAPS (ADR 0049; plano, Valor fixado 5; contrato
# P31): config/psychosocial/raas.yml, lido uma vez por processo e congelado.
# Chave desconhecida ou faltante recusa a carga (ArgumentError), para que um
# YAML editado à mão não deixe a crítica ou a remessa com lista pela metade.
module Psychosocial
  module Raas
    PATH = Rails.root.join("config/psychosocial/raas.yml").to_s.freeze
    KEYS = %w[version source review layout_version night_sigtap_code family_care_codes collective_codes procedure_prefixes
              origins destinations substances].freeze
    LISTS = %w[origins destinations substances].freeze

    module_function

    def config = @config ||= load(PATH)

    # -> Hash congelado (fundo). ArgumentError com a chave em falta ou a mais.
    def load(path)
      data = YAML.safe_load_file(path)
      raise ArgumentError, "raas.yml: não é um mapa" unless data.is_a?(Hash)

      unknown = data.keys - KEYS
      missing = KEYS - data.keys
      raise ArgumentError, "raas.yml: chave desconhecida #{unknown.join(', ')}" if unknown.any?
      raise ArgumentError, "raas.yml: chave faltante #{missing.join(', ')}" if missing.any?

      LISTS.each do |list|
        raise ArgumentError, "raas.yml: #{list} precisa ser um mapa de códigos em texto" unless
          data[list].is_a?(Hash) && data[list].keys.all?(String)
      end
      prefixes = data["procedure_prefixes"]
      raise ArgumentError, "raas.yml: procedure_prefixes precisa ser uma lista de prefixos SIGTAP (2 a 10 dígitos)" unless
        prefixes.is_a?(Array) && prefixes.any? && prefixes.all? { |p| p.is_a?(String) && p.match?(/\A\d{2,10}\z/) }

      deep_freeze(data)
    end

    # Rótulo do código na lista (origins, destinations, substances) ou nil.
    def label(list, code) = list_for(list)[code]

    def valid?(list, code) = code.is_a?(String) && list_for(list).key?(code)

    def list_for(list)
      name = list.to_s
      raise ArgumentError, "lista fora da RAAS: #{name}" unless LISTS.include?(name)

      config.fetch(name)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end

    private_class_method :list_for, :deep_freeze
  end
end
