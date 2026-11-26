module Regulation
  # Limites e constantes de envio da regulação à RNDS (módulo 26c, Valor 3).
  module RndsLimits
    BATCH_SIZE = 20
    INITIAL_RATE_PER_MINUTE = 60
    STALE_SENDING = 10.minutes
    BUDGET = 4.minutes
    GIVE_UP_AFTER = 15.days
    BLOCKED_RECHECK = 1.hour
    INITIAL_LOAD_DAYS = 30
    INITIAL_GRACE = 72.hours
    PAYLOAD_DAYS = 30
    LATE_HOUR = 23
    DEFAULT_SIGTAP = "0301010072".freeze
    MODALITY = "09".freeze
    CBO_GROUPS = %w[03 04].freeze
    SPECIALTY_SIGTAP_MAX = 500
    # A Task 4 cria Rnds::Errors::CODE e aponta esta constante para ela (M13).
    ERROR_CODE = /\A(EHR-ERR|EDS-MSG)\d{3}\z/
    REPLACED_CODE = "EDS-MSG009".freeze
    NOT_FINAL_CODE = "EHR-ERR825".freeze
  end
end
