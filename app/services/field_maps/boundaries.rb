require "csv"

# A caixa (bounding box) de cada município, do arquivo vendorizado do IBGE
# (módulo 24c, ADR 0053; Q33): vendor/ibge/2026-11-13/municipios_bbox.csv, com
# a origem e o SHA-256 no SOURCE ao lado. O recorte do mapa soma uma margem em
# volta, para o agente que anda na divisa do município.
module FieldMaps
  module Boundaries
    FILE = Rails.root.join("vendor/ibge/2026-11-13/municipios_bbox.csv")
    KM_PER_DEGREE = 111.32

    module_function

    # -> [min_lon, min_lat, max_lon, max_lat] | nil
    def bbox(ibge_code) = table[ibge_code.to_s]

    # A caixa alargada em `km` para cada lado; o grau de longitude encolhe com
    # a latitude (cosseno da latitude média). Nunca passa dos limites do globo.
    def with_margin(bbox, km: Catalog::MARGIN_KM)
      min_lon, min_lat, max_lon, max_lat = bbox
      lat = km / KM_PER_DEGREE
      lon = km / (KM_PER_DEGREE * Math.cos((min_lat + max_lat) / 2 * Math::PI / 180))
      [ [ min_lon - lon, -180.0 ].max, [ min_lat - lat, -90.0 ].max, [ max_lon + lon, 180.0 ].min, [ max_lat + lat, 90.0 ].min ]
        .map { |value| value.round(5) }
    end

    def table
      @table ||= CSV.foreach(FILE, headers: true).to_h do |row|
        [ row["ibge_code"], %w[min_lon min_lat max_lon max_lat].map { |key| Float(row[key]) } ]
      end.freeze
    end
    private_class_method :table
  end
end
