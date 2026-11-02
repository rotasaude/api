# Perfil RIA-R 2.0 lido de config/rnds/ria_r_2_0.yml (módulo 29, Desvio 14):
# canônicos dos perfis, CodeSystems, URLs de extensão e sistemas de
# identificador. `confirmed` = lido do perfil oficial (false enquanto for o
# esqueleto documentado; pendência do gate de homologação). Só configuração:
# nada de dado de paciente.
module Rnds
  Profile = Data.define(:composition_profile, :immunization_profile, :code_systems, :extensions, :identifiers, :document_type_code,
                        :confirmed, :review) do
    FILE = Rails.root.join("config/rnds/ria_r_2_0.yml").freeze
    SECTIONS = { code_systems: "code_systems", extensions: "extensions", identifiers: "identifiers" }.freeze

    def self.current = (@current ||= load_file)

    def self.load_file
      raw = YAML.safe_load_file(FILE)
      new(composition_profile: raw.fetch("composition_profile"), immunization_profile: raw.fetch("immunization_profile"),
          code_systems: symbolize(raw.fetch("code_systems")), extensions: symbolize(raw.fetch("extensions")),
          identifiers: symbolize(raw.fetch("identifiers")), document_type_code: raw.fetch("document_type_code"),
          confirmed: raw.fetch("confirmed"), review: raw.fetch("review", false))
    end

    def self.symbolize(hash) = hash.transform_keys(&:to_sym).freeze

    private_class_method :load_file, :symbolize
  end
end
