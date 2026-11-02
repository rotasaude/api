# Leitor dos YAML de config/vaccination (módulo 29, ADR 0047): carregados uma vez
# por processo, congelados em profundidade. Nome sem extensão.
module Vaccination
  module YamlFiles
    DIR = Rails.root.join("config/vaccination").freeze
    NAMES = %w[immunobiologicals rnds_terminologies calendar-2026 c2_schedule physical_loss_reasons].freeze
    CACHE = Concurrent::Map.new

    module_function

    def load(name)
      CACHE.compute_if_absent(name) { deep_freeze(YAML.safe_load_file(DIR.join("#{name}.yml"))) }
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |k, v| deep_freeze(k); deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end

    # Algum `review: true` em qualquer nível do documento.
    def review?(value)
      case value
      when Hash then value["review"] == true || value.each_value.any? { |v| review?(v) }
      when Array then value.any? { |v| review?(v) }
      else false
      end
    end
  end
end
