# Valores fixos do TFD (ADR 0048; plano, Valores fixados 4).
module Tfd
  module Catalog
    STATUSES = %w[draft submitted returned authorized denied scheduled travelling completed cancelled].freeze
    EVENT_KINDS = (STATUSES - %w[draft] + %w[created appointment_set inpatient_recorded]).freeze
    DECISIONS = { "authorize" => "authorized", "return" => "returned", "deny" => "denied" }.freeze
    MODES = %w[fleet bus_ticket air river].freeze
    TRANSPORT_MODES = MODES
    DIRECTIONS = %w[outbound return].freeze
    ALLOWANCE_KINDS = %w[meal_overnight meal_day ground_km air_miles river_miles].freeze
    PERSONS = %w[patient companion].freeze
    PAYMENT_METHODS = %w[cash transfer pix check].freeze
    PHYSICIAN_PREFIX = "225".freeze
    DEFAULT_MIN_DISTANCE_KM = 50
    KM_UNIT = 50
    AIR_MILES_UNIT = 200
    RIVER_NM_UNIT = 27
    KM_PER_MILE = 1.609344
    KM_PER_NM = 1.852
    JUSTIFICATION = (20..2000)
    REASON = (10..500)
    RECEIPT_MAX = 40
    CARRIER_MAX = 120 # T18 (empresa: até 120)
    MAX_AMOUNT_CENTS = 10_000_000
    TRAIL_ACCESS = "tfd".freeze
    FILE_PURPOSE = "tfd_accountability".freeze
  end
end
