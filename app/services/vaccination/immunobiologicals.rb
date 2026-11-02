# Catálogo de imunobiológicos (config/vaccination/immunobiologicals.yml; código
# LEDI APS 8.7.0). `routine: false` = aceito em transcrição, fora do estoque padrão.
module Vaccination
  module Immunobiologicals
    Manufacturer = Data.define(:code, :key, :name, :validity_after_opening_hours, :review)
    Product = Data.define(:code, :name, :multidose, :doses_per_vial, :default_route, :default_site, :manufacturers, :review, :routine) do
      # Pela `key` estável do fabricante (V19); o `code` pode ser nulo e não identifica.
      def manufacturer(key) = manufacturers.find { |m| m.key == key.to_s }
    end

    module_function

    def all = (@all ||= build.freeze)
    # Código canônico do LEDI, sem zero à esquerda: find("09") == find("9").
    def normalize(code) = code.to_s.strip.sub(/\A0+(?=\d)/, "")
    def find(code) = by_code[normalize(code)]
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
