# Listas fechadas da urgência (ADR 0050). Contrato Q2: só enfermagem (2235)
# classifica o risco (COFEN 661/2021); o médico é 225*.
module Urgency
  module Catalog
    COLORS = %w[red orange yellow green blue].freeze
    DEFAULT_MAX_WAIT = { "red" => 0, "orange" => 10, "yellow" => 60, "green" => 120, "blue" => 240 }.freeze
    STATES = %w[waiting_classification classified in_care closed].freeze
    OUTCOMES = %w[discharged discharged_to_primary_care transferred left_without_care left_against_advice death].freeze
    IDENTIFIED_OUTCOMES = %w[discharged discharged_to_primary_care transferred].freeze
    OUTCOME_MAP = {
      "discharged" => "discharged",
      "death" => "discharged",
      "discharged_to_primary_care" => "referred",
      "transferred" => "referred",
      "left_without_care" => "left",
      "left_against_advice" => "left"
    }.freeze
    CLASSIFIER_CBO_PREFIXES = %w[2235].freeze
    PHYSICIAN_CBO_PREFIX = "225".freeze
    COMPLAINT = (3..500)
    JUSTIFICATION = (10..500)
    DESCRIPTION = (10..500)
    DESTINATION = (3..200)
    VACANCY_REQUEST_MAX = 500
    RETURN_DAYS = (1..90)
    RETURN_REASON = (3..300)
    PAIN = (0..10)
    CALL_KINDS = %w[classification care].freeze
    TRAIL_ACCESS = "urgency".freeze
    UNIDENTIFIED_REASON = "unidentified".freeze
    COUNTER_REFERRAL_WINDOW = 60.days
  end
end
