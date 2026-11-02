# Perfil RIA-R 2.0 lido de config/rnds/ria_r_2_0.yml (módulo 29, Desvio 14):
# canônicos dos perfis, CodeSystems, URLs de extensão e sistemas de
# identificador. `confirmed` = lido do perfil oficial (false enquanto for o
# esqueleto documentado; pendência do gate de homologação). Só configuração:
# nada de dado de paciente.
module Rnds
  Profile = Data.define(:composition_profile, :immunization_profile, :code_systems, :extensions, :identifiers, :document_type_code,
                        :confirmed, :review, :hypotheses) do
    FILE = Rails.root.join("config/rnds/ria_r_2_0.yml").freeze
    SECTIONS = %w[code_systems extensions identifiers].freeze

    def self.current = (@current ||= load_file)

    def self.load_file
      raw = YAML.safe_load_file(FILE)
      sections = SECTIONS.to_h { |name| [ name, raw.fetch(name).transform_keys(&:to_sym) ] }
      # "section.key" de cada URL/código marcado `hypothesis: true` (a conferir na homologação).
      hypotheses = sections.flat_map { |name, items| items.select { |_, v| v["hypothesis"] }.keys.map { |key| "#{name}.#{key}" } }
      hypotheses << "document_type_code" if raw.fetch("document_type_code")["hypothesis"]
      new(composition_profile: raw.fetch("composition_profile"), immunization_profile: raw.fetch("immunization_profile"),
          code_systems: urls(sections["code_systems"]), extensions: urls(sections["extensions"]),
          identifiers: urls(sections["identifiers"]), document_type_code: raw.fetch("document_type_code").fetch("value"),
          confirmed: raw.fetch("confirmed"), review: raw.fetch("review", false), hypotheses: hypotheses.freeze)
    end

    def self.urls(items) = items.transform_values { |v| v.fetch("url") }.freeze

    private_class_method :load_file, :urls
  end
end
