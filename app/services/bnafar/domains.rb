# Domínios do SI-BNAFAR lidos de config/bnafar (módulo 27b): carregados uma vez, congelados em profundidade.
module Bnafar
  module Domains
    DIR = Rails.root.join("config/bnafar").freeze

    module_function

    def dm01 = domains.fetch("dm01")
    def dm12 = domains.fetch("dm12")
    def dm13 = domains.fetch("dm13")
    # DM14 inteira: [{ "code", "label", "product_type", "review" }].
    def programs = (@programs ||= freeze_deep(YAML.safe_load_file(DIR.join("programs.yml")).fetch("programs")))
    def mappings = domains

    def domains = (@domains ||= freeze_deep(YAML.safe_load_file(DIR.join("domains.yml"))))

    def freeze_deep(value)
      case value
      when Hash then value.each { |k, v| freeze_deep(k); freeze_deep(v) }
      when Array then value.each { |v| freeze_deep(v) }
      end
      value.freeze
    end
    private_class_method :freeze_deep
  end
end
