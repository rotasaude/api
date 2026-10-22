# Carga inicial do catálogo-base (config/care_lines/catalog-base.yml, a
# tabela da prova técnica). Idempotente: só cria a versão 1 da chave que
# não existe; nunca sobrescreve a curadoria do maintenance.
module CareLines
  module Templates
    module Load
      DEFAULT_PATH = Rails.root.join("config/care_lines/catalog-base.yml")

      module_function

      # aliases: true — o YAML repete listas por âncora (&md_nurse, &syphilis, &hiv).
      def entries(path = DEFAULT_PATH) = YAML.safe_load_file(path, aliases: true)

      def call(path = DEFAULT_PATH)
        created = entries(path).count do |entry|
          next false if CareLineTemplate.exists?(key: entry.fetch("key"))

          result = Save.call(entry)
          raise ArgumentError, "catálogo-base: #{entry['key']} #{result.reason} #{result.details}" if result.failure?

          true
        end
        { created: created }
      end
    end
  end
end
