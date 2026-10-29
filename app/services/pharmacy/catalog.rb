# Constantes do módulo 27a (ADR 0045): locais, papéis, movimentos, limites de
# entrada e parâmetros da cidade. Fonte única de formatos: contrato do módulo.
module Pharmacy
  module Catalog
    LOCATION_KINDS = %w[central unit].freeze
    ROLES = %w[pharmacist pharmacy_assistant stock_keeper].freeze
    DISPENSER_ROLES = %w[pharmacist pharmacy_assistant].freeze

    MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return].freeze
    POSITIVE_KINDS = %w[opening receipt donation transfer_in return].freeze
    NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry].freeze

    ENTRY_KINDS = %w[invoice donation opening].freeze
    ENTRY_MOVEMENT = { "invoice" => "receipt", "donation" => "donation", "opening" => "opening" }.freeze

    TRANSFER_STATUSES = %w[sent received received_with_difference].freeze
    ADJUSTMENT_KINDS = %w[adjustment loss expiry].freeze
    ADJUSTMENT_STATUSES = %w[applied pending approved rejected].freeze
    PRESCRIPTION_KINDS = %w[digital external].freeze

    # Farmacêutico: CBO 2234* (Portaria 344 e conselho de farmácia).
    PHARMACIST_CBO_PREFIX = "2234".freeze
    COUNCILS = %w[CRM CRO COREN].freeze
    NOTIFICATION_LISTS = %w[A1 A2 A3 B1 B2].freeze
    CONTROLLED_VALIDITY_DAYS = 30

    DEFAULT_SETTINGS = { "common_validity_days" => 30, "continuous_validity_days" => 180,
                         "continuous_interval_days" => 25, "expiry_alert_days" => 90,
                         "adjustment_approval_percent" => 10 }.freeze
    SETTING_RANGES = { "common_validity_days" => 1..365, "continuous_validity_days" => 1..365,
                       "continuous_interval_days" => 1..90, "expiry_alert_days" => 1..365,
                       "adjustment_approval_percent" => 0..100 }.freeze

    QUANTITY = /\A\d{1,5}(\.\d{1,2})?\z/
    REASON = (10..500)
    NAME_MAX = 120
    LOT_NUMBER = %r{\A[0-9A-Za-z./-]{1,40}\z}
    DOCUMENT_NUMBER = %r{\A[0-9A-Za-z./-]{1,60}\z}
    SUPPLIER_MAX = 120
    MANUFACTURER_MAX = 120
    NOTIFICATION_NUMBER = %r{\A[0-9A-Za-z./-]{1,30}\z}
    COUNCIL_NUMBER = /\A[0-9]{1,10}\z/
    UF = /\A[A-Z]{2}\z/
    PACKAGE_RANGE = (1..10_000)

    MAX_ENTRY_ITEMS = 100
    MAX_TRANSFER_ITEMS = 100
    MAX_DISPENSE_ITEMS = 20
    MAX_EXTERNAL_ITEMS = 20
    DOSAGE = (3..500)
    MAX_MINIMUM_ROWS = 500
    SEARCH_QUERY_MAX = 60
    QUANTITY_UNIT_MAX = 30
    LOOKUP_DAYS = 365
    LOOKUP_MAX = 20

    # `access` do clinical_record.viewed gravado pela farmácia.
    TRAIL_ACCESS = "pharmacy".freeze

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
  end
end
