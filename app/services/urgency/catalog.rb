# Listas fechadas da urgência (ADR 0050). Contrato Q2: só enfermagem (2235)
# classifica o risco (COFEN 661/2021); o médico é 225*.
module Urgency
  module Catalog
    COLORS = %w[red orange yellow green blue].freeze
    DEFAULT_MAX_WAIT = { "red" => 0, "orange" => 10, "yellow" => 60, "green" => 120, "blue" => 240 }.freeze
    STATES = %w[waiting_classification classified in_care closed].freeze
    # Contrato §7 e §14 Q25: `registered_in_error` é o encontro aberto por
    # engano ou em duplicidade — motivo obrigatório (ERROR_REASON, cifrado),
    # sem BPA (Task 13: Billing::FromUrgency pula NON_CARE_OUTCOMES), fora das
    # contagens de evasão e de desfecho do painel (Task 15) e fora da visão do
    # cidadão (Task 14).
    REGISTERED_IN_ERROR = "registered_in_error".freeze
    OUTCOMES = (%w[discharged discharged_to_primary_care transferred left_without_care left_against_advice death] +
                [ REGISTERED_IN_ERROR ]).freeze
    NON_CARE_OUTCOMES = [ REGISTERED_IN_ERROR ].freeze
    IDENTIFIED_OUTCOMES = %w[discharged discharged_to_primary_care transferred].freeze
    # Q10/Q25: os que a recepção e a enfermagem também registram, em qualquer
    # estado antes do fechamento; os demais, só o médico (225*) e com a
    # consulta de urgência finalizada. Q30: `registered_in_error` só sem a
    # consulta finalizada (para todos); `left_without_care` vale com ela (§7).
    DESK_OUTCOMES = [ "left_without_care", REGISTERED_IN_ERROR ].freeze
    # Desvio 13 (+ Q25): o `outcome` do 13 de cada desfecho.
    OUTCOME_MAP = {
      "discharged" => "discharged",
      "death" => "discharged",
      "discharged_to_primary_care" => "referred",
      "transferred" => "referred",
      "left_without_care" => "left",
      "left_against_advice" => "left",
      REGISTERED_IN_ERROR => "left"
    }.freeze
    CLASSIFIER_CBO_PREFIXES = %w[2235].freeze
    PHYSICIAN_CBO_PREFIX = "225".freeze
    # Módulo 32b: quem checa a medicação é a enfermagem (2235), o técnico (3222)
    # ou o médico (225*).
    NURSING_TECH_CBO_PREFIX = "3222".freeze
    CHECKER_CBO_PREFIXES = %w[2235 3222 225].freeze
    BED_LABEL = (1..20)
    STAY_END_KINDS = %w[bed_change observation_ended outcome].freeze
    OBSERVATION_NEAR_LIMIT_HOURS = 20
    OBSERVATION_LIMIT_HOURS = 24
    PRESCRIPTION_STATUSES = %w[active superseded suspended ended].freeze
    PRESCRIPTION_ITEMS = (1..20)
    FREQUENCY_KINDS = %w[once interval if_needed].freeze
    INTERVAL_HOURS = (1..24)
    MAX_PER_DAY = (1..24)
    DOSE = /\A\d{1,5}(\.\d{1,3})?\z/
    DOSE_UNITS = %w[mg mcg g mL UI mEq gota comprimido capsula ampola frasco jato aplicacao sache].freeze
    INSTRUCTIONS_MAX = 500
    SUSPENSION_REASON = (10..500)
    FIRST_DOSE_WINDOW = (-1.hour..24.hours)
    SCHEDULE_AHEAD = 24.hours
    IF_NEEDED_WINDOW = 24.hours
    ADMINISTRATION_STATUSES = %w[administered not_administered refused].freeze
    ADMINISTRATION_REASON = (10..500)
    ADMINISTERED_AT_TOLERANCE = 5.minutes
    # §12 Q5: um horário pode ser checado até 60 min antes de vencer (mais cedo → slot_not_due).
    SLOT_DUE_AHEAD = 60.minutes
    DETAIL_ADMINISTRATIONS_WINDOW = 48.hours
    SHORTFALL_CAUSES = %w[no_location insufficient_balance lot_unavailable].freeze
    RECONCILIATION_NOTE = (10..500)
    COMPLAINT = (3..500)
    JUSTIFICATION = (10..500)
    DESCRIPTION = (10..500)
    DESTINATION = (3..200)
    VACANCY_REQUEST_MAX = 500
    RETURN_DAYS = (1..90)
    RETURN_REASON = (3..300)
    ERROR_REASON = (10..500)
    PAIN = (0..10)
    CALL_KINDS = %w[classification care].freeze
    TRAIL_ACCESS = "urgency".freeze
    UNIDENTIFIED_REASON = "unidentified".freeze
    COUNTER_REFERRAL_WINDOW = 60.days
  end
end
