# Códigos do módulo 23 (ADR 0040; contrato §1; plano, "Valores fixados" 2).
module CareLines
  module Catalog
    TEMPLATE_KEYS = %w[child_c2 pregnancy_c3 diabetes_c4 hypertension_c5 elderly_c6 women_c7].freeze
    INDICATORS = { "child_c2" => "C2", "pregnancy_c3" => "C3", "diabetes_c4" => "C4", "hypertension_c5" => "C5",
                   "elderly_c6" => "C6", "women_c7" => "C7" }.freeze
    SOURCE_FORMAT = /\A(consultation|blood_pressure|weight_height|acs_visit|oral_health|exam:02\d{8}|procedure:\d{10}|vaccine:[a-z0-9_]{1,30})\z/
    # Visita do ACS (módulo 24b): medida só com `home_visits` utilizável; sem ele, não rastreada.
    UNTRACKED_SOURCE = /\A(acs_visit)\z/
    # Vacina (módulo 29): medida só com `vaccination` utilizável; sem ele, não rastreada.
    VACCINE_SOURCE = /\Avaccine:.+\z/
    C2_SOURCE = "vaccine:c2_schedule".freeze
    # unchecked: marco de vacina com a caderneta não conferida ("não conferido";
    # contrato §10) — nunca pendência, fora do pior da linha e do denominador da prévia.
    STATUSES = %w[ok due_soon overdue untracked unchecked].freeze
    SCHEDULES = %w[proportional end_of_window].freeze
    ANCHORS = %w[enrollment birth lmp rolling].freeze
    SUGGESTION_REASONS = %w[problem age_sex declared resolved_problem].freeze
    END_REASONS = %w[discharge death moved pregnancy_ended other].freeze
    CHANNELS = %w[phone home_visit wpda_message in_person].freeze
    OUTCOMES = %w[reached no_answer scheduled refused].freeze
    CONDITIONS = %w[diabetes hypertension pregnancy mental_health none].freeze
    CONDITION_TEMPLATE = { "diabetes" => "diabetes_c4", "hypertension" => "hypertension_c5", "pregnancy" => "pregnancy_c3" }.freeze
    # contrato §11 L3
    CONFIRM_CBO_PREFIXES = %w[2231 2251 2252 2253 2235].freeze
    TEXT_MAX = 500
    DUE_SOON_DAYS = 30
    LMP_MAX_AGE_DAYS = 336

    module_function

    def untracked?(source, vaccination: false, home_visits: false)
      (!home_visits && source.to_s.match?(UNTRACKED_SOURCE)) || (!vaccination && vaccine?(source))
    end

    def vaccine?(source) = source.to_s.match?(VACCINE_SOURCE)
  end
end
