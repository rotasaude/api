# Constantes do envio ao SI-BNAFAR (módulo 27b, Valor 3).
module Bnafar
  module Catalog
    ENVIRONMENTS = %w[homologation production].freeze
    SUBJECTS = %w[position exit].freeze
    SUBMISSION_STATUSES = %w[building queued sending processing finished failed lost].freeze
    BATCH_STATUSES = %w[queued sending processing finished failed].freeze
    BATCH_OPERATIONS = %w[post put delete].freeze
    RECORD_STATUSES = %w[pending accepted rejected].freeze
    LINK_KINDS = %w[exit deletion late_reversal].freeze
    PENDENCY_CODES = %w[lot_incomplete lot_number_too_long location_without_cnes product_without_code
                        fractional_balance exit_type_missing domain_off].freeze
    EXTERNAL_EXIT_TYPES = %w[S-DF S-TR S-D S-E].freeze
    DESTINATION_KINDS = %w[cnes cnpj].freeze
    REASON = (10..500)
    CNES = /\A\d{7}\z/
    ANVISA = /\A(\d{11}|\d{13})\z/
    AMPP = /\A[@0-9A-Za-z]{1,25}\z/
    IUM = /\A[0-9A-Za-z]{1,20}\z/
    LOT_NUMBER_MAX = 30
    INTERNATIONAL_NAME_MAX = 120
    UNIT_PRICE_CENTS = (1..2_000_000_000)
    MSG_CODE = /\A[A-Za-z0-9_-]{2,20}\z/
    BUILD_HOUR = 1
    LATE_HOUR = 15
    CORRECTION_DAYS = 30
    PAYLOAD_DAYS = 30
    # Os nove do contrato §9, na ordem, mais `bnafar_record.deleted` (Q14).
    DOMAIN_EVENTS = %w[bnafar_submission.queued bnafar_submission.finished bnafar_submission.lost
                       bnafar_record.rejected bnafar_record.corrected stock_external_exit.recorded
                       stock_lot.bnafar_completed opening_import.applied opening_import.reverted
                       bnafar_record.deleted].freeze
  end
end
