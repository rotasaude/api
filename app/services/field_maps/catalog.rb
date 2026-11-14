# Constantes do mapa offline por município (módulo 24c, ADR 0053; contrato
# §3.1; Q19, Q23, Q31). Espelhadas nos CHECKs de field_maps e field_map_bases.
module FieldMaps
  module Catalog
    STATES = %w[building ready failed].freeze
    ERROR_CODES = %w[base_missing extract_failed boundary_missing].freeze
    BASE_STATES = %w[copying ready failed].freeze
    # O maintenance avisa quando a base passa disto (não há job recorrente).
    BASE_STALE_DAYS = 90
    # Margem em volta da caixa do município e zoom máximo do recorte.
    MARGIN_KM = 2
    MAXZOOM = 15
    KEY_BASE = "field-maps/base/%<version>s.pmtiles".freeze
    # O SHA na chave separa duas gerações da mesma versão da base (Q31).
    KEY_CITY = "field-maps/cities/%<city_id>s/%<version>s-%<sha12>s.pmtiles".freeze
    EVENTS = %w[field_map.built field_map.failed].freeze
    AUDIT = %w[maintenance.field_map.build_requested maintenance.field_map.base_refresh_requested].freeze
  end
end
