# Módulo 29 (ADR 0047): constantes da sala de vacina (Valor fixado 3). Task 2:
# nasce com as constantes e `under_review? = false`; a Task 4 troca a
# implementação para olhar os YAML com `review: true`.
module Vaccination
  module Catalog
    LOCATION_KINDS = %w[cold_chain_central vaccine_room].freeze
    ROOM_ROLES = %w[vaccinator room_lead].freeze
    VACCINATOR_CBO_PREFIXES = %w[3222 2235 2251 2252 2253].freeze
    ROOM_LEAD_CBO_PREFIX = "2235".freeze
    CHECK_MODES = %w[transcribed confirmed_complete born_after_go_live].freeze
    ITEM_STATUSES = %w[due overdue upcoming complete not_applicable unchecked].freeze
    RNDS_STATUSES = %w[not_sent pending sending accepted rejected failed blocked].freeze
    OUTBOX_STATUSES = %w[pending sending accepted rejected failed blocked].freeze
    BLOCK_REASONS = %w[professional_cns_not_in_cnes patient_identity_unverified patient_without_cns_or_cpf].freeze
    EQUIPMENT_KINDS = %w[refrigerator chamber freezer].freeze
    VIAL_STATUSES = %w[open expired closed_out].freeze
    EXCURSION_DECISIONS = %w[use discard].freeze
    REASON = (10..500)
    PENDING_AFTER = 20.hours
    DEADLINE = 24.hours
    GIVE_UP_AFTER = 15.days
    MAX_TRANSCRIPTION_ITEMS = 40
    TRAIL_ACCESS = "vaccination".freeze
    DEFAULT_RANGE_C = [ 2, 8 ].freeze
    READINGS_PER_DAY = 2
    TEXT_MAX = 120

    module_function

    # Task 4 troca por: qualquer YAML do módulo com `review: true`.
    def under_review? = false
  end
end
