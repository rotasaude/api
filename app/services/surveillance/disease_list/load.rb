# Carga inicial da lista nacional (config/surveillance/notifiable-diseases.yml,
# a prova técnica da Task 0). Idempotente: só cria a versão 1 com a tabela vazia;
# nunca sobrescreve a curadoria do maintenance.
module Surveillance
  module DiseaseList
    module Load
      DEFAULT_PATH = Rails.root.join("config/surveillance/notifiable-diseases.yml")

      module_function

      def call(path = DEFAULT_PATH)
        data = YAML.safe_load_file(path, aliases: true, permitted_classes: [ Date ])
        created = DiseaseList.with_lock do
          next 0 if NotifiableDiseaseVersion.exists?

          checked = DiseaseList.validate(data.fetch("diseases"))
          raise ArgumentError, "lista nacional: #{checked.reason} #{checked.details}" if checked.failure?

          DiseaseList.create_version!(version: 1, ordinance: data.fetch("ordinance"), effective_from: Date.parse(data.fetch("effective_from").to_s),
                                      diseases: data.fetch("diseases"), sources: header_sources(data))
          1
        end
        { created: created }
      end

      # Proveniência da versão: portaria e pasta das fontes (e data da coleta, se houver).
      def header_sources(data)
        { "ordinance" => data["ordinance"], "sources_dir" => data["sources_dir"], "fetched_on" => data["fetched_on"]&.to_s }.compact
      end
      private_class_method :header_sources
    end
  end
end
