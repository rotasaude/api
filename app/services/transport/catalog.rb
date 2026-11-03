# Valores fixos do transporte sanitário (ADR 0048; plano, Valores fixados 3).
module Transport
  module Catalog
    VEHICLE_KINDS = %w[van minibus bus car ambulance_a].freeze
    LICENSE_CATEGORIES = %w[B C D E].freeze
    LARGE_VEHICLE_SEATS = 8
    LARGE_VEHICLE_CATEGORIES = %w[D E].freeze
    LICENSE_WARNING_DAYS = 30
    TRIP_STATUSES = %w[planned confirmed in_progress done cancelled].freeze
    STOP_KINDS = %w[boarding destination].freeze
    ORIGINS = %w[regulation appointment tfd series exception].freeze
    EXCEPTION_REASONS = %w[follow_up_return legacy_patient scheduling_pending other].freeze
    ATTENDANCE = %w[pending boarded no_show].freeze
    NOTICE_KINDS = %w[added departure_changed boarding_changed cancelled removed reminder].freeze
    DEPARTURE_CHANGE = 30.minutes
    SERIES_HORIZON_DAYS = 21
    PENDING_REASONS = %w[no_seat no_wheelchair_spot].freeze
    EXPENSE_KINDS = %w[toll parking meal other].freeze
    PLATE = /\A[A-Z]{3}\d[A-Z\d]\d{2}\z/
    RENAVAM = /\A\d{11}\z/
    LICENSE_NUMBER = /\A\d{11}\z/
    IBGE = /\A\d{7}\z/
    CNES = /\A\d{7}\z/
    SEATS = (1..60)
    WHEELCHAIR_SPOTS = (0..10)
    MAX_TRIP_HOURS = 72
    ODOMETER = (0..9_999_999)
    REASON = (10..500)
    TEXT_MAX = 120
    MODEL = (2..80)
    NAME = (2..120)
    DISTANCE_KM = (0..9_999)
    RENEM_MAX = 20
    ADDRESS_MAX = 200
    DEFAULT_COMPANION_RULE = { "max_age_child" => 15, "min_age_elderly" => 60 }.freeze
    # §14 T18: acompanhante (nome 3–120, documento até 20).
    COMPANION_NAME = (3..120)
    COMPANION_DOCUMENT_MAX = 20
    # Viagens que aceitam escrita de passageiro (T19: o resto → trip_not_open).
    OPEN_STATUSES = %w[planned confirmed].freeze
    # Trilha da busca de pessoa e dos duplicados da central (T2).
    TRAIL_ACCESS = "transport".freeze
  end
end
