# Interruptores de funcionalidade por cidade (ADR 0028; spec 2026-10-05 §3.1;
# contratos §2). O catálogo mora no código; o estado por cidade, em
# city_features (plataforma). `requires` diz o que precisa existir para a
# funcionalidade ser UTILIZÁVEL; ligado e utilizável são coisas diferentes.
module Platform
  module Features
    Entry = Data.define(:key, :description, :requires)

    CATALOG = [
      Entry.new(key: "ledi_export",
                description: "Exportação contínua da produção (LEDI APS) para o PEC da cidade",
                requires: %w[record_mode pec_url ibge_code credential:ledi]),
      Entry.new(key: "cadsus_lookup",
                description: "Consulta ao CADSUS na validação presencial",
                requires: %w[credential:cadsus])
    ].freeze

    KEYS = CATALOG.map(&:key).freeze

    module_function

    def find(key) = CATALOG.find { |entry| entry.key == key.to_s }
  end
end
