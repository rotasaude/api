# Catálogo de imunobiológicos (config/vaccination/immunobiologicals.yml; código
# LEDI APS 8.7.0). `routine: false` = aceito em transcrição, fora do estoque padrão.
module Vaccination
  module Immunobiologicals
    # Módulo 27b (Q21): `cnpj` do fabricante (nulo até o gate de go-live) e
    # `obm_vmp` do produto (código VMP da OBM, idem) moram no YAML, nunca no lote.
    # Ambos opcionais na construção (quem monta sem eles fica com nil).
    Manufacturer = Data.define(:code, :key, :name, :validity_after_opening_hours, :review, :cnpj) do
      def initialize(cnpj: nil, **rest) = super(cnpj: cnpj, **rest)
    end
    Product = Data.define(:code, :name, :multidose, :doses_per_vial, :default_route, :default_site, :manufacturers, :review, :routine, :obm_vmp) do
      def initialize(obm_vmp: nil, **rest) = super(obm_vmp: obm_vmp, **rest)

      # Pela `key` estável do fabricante (V19); o `code` pode ser nulo e não identifica.
      def manufacturer(key) = manufacturers.find { |m| m.key == key.to_s }
    end

    module_function

    def all = (@all ||= build.freeze)
    # Código canônico do LEDI, sem zero à esquerda: find("09") == find("9").
    def normalize(code) = code.to_s.strip.sub(/\A0+(?=\d)/, "")
    def find(code) = by_code[normalize(code)]
    def by_code = (@by_code ||= all.index_by(&:code).freeze)

    # Fabricante do produto pelo CNPJ (Cnpj.normalize: aceita máscara e
    # alfanumérico). nil se o CNPJ é inválido ou nenhum fabricante o tem.
    def manufacturer_by_cnpj(product, cnpj)
      wanted = Cnpj.normalize(cnpj)
      return nil unless wanted

      product.manufacturers.find { |m| m.cnpj && Cnpj.normalize(m.cnpj) == wanted }
    end

    def build
      YamlFiles.load("immunobiologicals").fetch("products").map do |row|
        mans = row.fetch("manufacturers").map do |m|
          Manufacturer.new(code: m["code"], key: m.fetch("key"), name: m.fetch("name"),
                           validity_after_opening_hours: m.fetch("validity_after_opening_hours"), review: m.fetch("review"),
                           cnpj: m.fetch("cnpj"))
        end
        Product.new(code: row.fetch("code"), name: row.fetch("name"), multidose: row.fetch("multidose"),
                    doses_per_vial: row.fetch("doses_per_vial"), default_route: row.fetch("default_route"),
                    default_site: row.fetch("default_site"), manufacturers: mans.freeze, review: row.fetch("review"),
                    routine: row.fetch("routine", true), obm_vmp: row.fetch("obm_vmp"))
      end
    end
    private_class_method :build
  end
end
