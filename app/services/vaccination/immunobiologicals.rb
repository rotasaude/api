# Catálogo de imunobiológicos (config/vaccination/immunobiologicals.yml; código
# LEDI APS 8.7.0). `routine: false` = aceito em transcrição, fora do estoque padrão.
module Vaccination
  module Immunobiologicals
    Manufacturer = Data.define(:code, :key, :name, :validity_after_opening_hours, :review)
    Product = Data.define(:code, :name, :multidose, :doses_per_vial, :default_route, :default_site, :manufacturers, :review, :routine) do
      # Por código RNDS do fabricante (quando houver) ou pela chave do YAML.
      def manufacturer(code_or_key)
        value = code_or_key.to_s
        return nil if value.empty?

        manufacturers.find { |m| m.key == value || (m.code && m.code == value) }
      end
    end

    module_function

    def all = (@all ||= build.freeze)
    def find(code) = by_code[code.to_s]
    def by_code = (@by_code ||= all.index_by(&:code).freeze)

    def build
      YamlFiles.load("immunobiologicals").fetch("products").map do |row|
        mans = row.fetch("manufacturers").map do |m|
          Manufacturer.new(code: m["code"], key: m.fetch("key"), name: m.fetch("name"),
                           validity_after_opening_hours: m.fetch("validity_after_opening_hours"), review: m.fetch("review"))
        end
        Product.new(code: row.fetch("code"), name: row.fetch("name"), multidose: row.fetch("multidose"),
                    doses_per_vial: row.fetch("doses_per_vial"), default_route: row.fetch("default_route"),
                    default_site: row.fetch("default_site"), manufacturers: mans.freeze, review: row.fetch("review"),
                    routine: row.fetch("routine", true))
      end
    end
    private_class_method :build
  end
end
