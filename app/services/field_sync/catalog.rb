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
    TOMBSTONE_ENTITY_TYPES = %w[household registration].freeze
    TOMBSTONE_REASONS = %w[moved erased].freeze # gravadas; out_of_scope só existe no download
    REVOKED_REASONS = %w[user admin membership_ended user_disabled].freeze
    # Revogação com autor (revoked_by_user_id; ck_field_devices_revoked_by).
    REVOKED_BY_PERSON = %w[user admin].freeze
    # O que a borda de /field/v1 (FieldAuthentication) responde; todos em
    # domains-v1.json errors.http (spec/services/field_sync/domains_spec.rb).
    HTTP_ERRORS = %w[too_many_requests feature_disabled invalid_token device_revoked json_required payload_too_large].freeze
  end
end
