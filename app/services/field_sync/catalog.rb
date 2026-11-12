# Constantes da sincronização do aparelho de campo (módulo 24b, ADR 0052;
# contrato field-sync-v1). Os eventos field_device.* moram em HomeVisits::Catalog.
module FieldSync
  module Catalog
    CONTRACT = "field-sync-v1".freeze
    TOKEN_PREFIX = "rsf_".freeze
    TOKEN_BYTES = 32
    QR_PREFIX = "rotasaude-field:v1:".freeze
    MAX_ACTIVE_DEVICES = 3
    DEVICE_NAME = (1..60)
    ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration].freeze
    MAX_ITEMS = 50
    MAX_BODY_BYTES = 2.megabytes
    PAGE_LIMIT = (1..500)
    DEFAULT_PAGE = 200
    CUTOFF = 2.seconds
    RATE = 120
    LAST_USED_EVERY = 1.minute
    REMOVAL_REASONS = %w[moved erased out_of_scope].freeze
    REVOKED_REASONS = %w[user admin membership_ended user_disabled].freeze
  end
end
