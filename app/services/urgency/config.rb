# config/urgency/sigtap.yml: códigos SIGTAP da UPA, sob revisão (gate de
# go-live). Lido uma vez e congelado; chave desconhecida ou ausente falha.
module Urgency
  module Config
    PATH = Rails.root.join("config/urgency/sigtap.yml")
    KEYS = %w[version review source classification_code care_code].freeze

    module_function

    def sigtap = @sigtap ||= load(PATH)

    def load(path)
      data = YAML.safe_load_file(path)
      raise ArgumentError, "sigtap.yml: não é um mapa" unless data.is_a?(Hash)

      unknown = data.keys - KEYS
      missing = KEYS - data.keys
      raise ArgumentError, "sigtap.yml: chave desconhecida #{unknown.join(', ')}" if unknown.any?
      raise ArgumentError, "sigtap.yml: chave ausente #{missing.join(', ')}" if missing.any?

      data.each_value(&:freeze)
      data.freeze
    end
  end
end
