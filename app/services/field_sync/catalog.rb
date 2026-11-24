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
    # Módulo 35a (W-4): a instalação e a coleta da ovitrampa, no fim. Módulo
    # 35b (§11): o animal, a vacina antirrábica, a coleta de LV e a coleira.
    ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration family
                    ovitrap_installation ovitrap_collection animal rabies_vaccination leish_collection collar].freeze
    MAX_ITEMS = 50
    MAX_BODY_BYTES = 2.megabytes
    PAGE_LIMIT = (1..500)
    DEFAULT_PAGE = 200
    CUTOFF = 2.seconds
    RATE = 120
    LAST_USED_EVERY = 1.minute
    REMOVAL_REASONS = %w[moved erased out_of_scope].freeze
    # Módulo 35b (Q21): o animal que sai do escopo ou de active e o inquérito
    # de LV que fecha ou sai do escopo gravam lápide out_of_scope (triggers do
    # bloco "Módulo 35b — app de campo" do db/city_triggers.sql).
    TOMBSTONE_ENTITY_TYPES = %w[household registration animal leish_survey].freeze
    TOMBSTONE_REASONS = %w[moved erased out_of_scope].freeze
    REVOKED_REASONS = %w[user admin replaced membership_ended user_disabled].freeze
    # Módulo 24c (Q17): revogação que o tablet não escolheu (substituição do
    # aparelho, fim de vínculo, usuário desativado) responde device_suspended,
    # e o app guarda a fila; device_revoked fica só para user e admin.
    SUSPENDED_REASONS = %w[replaced membership_ended user_disabled].freeze
    # Revogação com autor (revoked_by_user_id; ck_field_devices_revoked_by). A
    # substituição (replaced) é do dono, ao cadastrar o aparelho novo.
    REVOKED_BY_PERSON = %w[user admin replaced].freeze
    # O que a borda de /field/v1 (FieldAuthentication) responde; todos em
    # domains-v1.json errors.http (spec/services/field_sync/domains_spec.rb).
    HTTP_ERRORS = %w[too_many_requests feature_disabled invalid_token device_revoked json_required payload_too_large
                     device_suspended map_not_found range_not_satisfiable].freeze
    # Módulo 24c (ADR 0053): referência offline e mapa por município.
    REFERENCE_CACHE = 5.minutes
    MAP_CONTENT_TYPE = "application/vnd.pmtiles".freeze
    MAP_CHUNK = 1.megabyte
  end
end
